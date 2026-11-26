// StayAwake for Mac — native version of the Library app.
// Single-file AppKit app: menu bar item + floating always-on-top mini timer.
//
// Features (mirroring the Library version):
//   - Preset durations 15m / 30m / 1h / 2h / 4h / 8h, custom minutes, indefinite
//   - IOKit power assertions keep the Mac (and optionally the display) awake
//   - Floating mini timer panel: level .floating, joins all Spaces, visible
//     over other apps and in full screen, draggable, with countdown/elapsed,
//     progress bar, end time, +15 min and Stop
//   - Low-battery guard: auto-stop at <= 20% while discharging (on by default)
//   - Optional: deactivate when switching to battery; allow display to sleep
//   - The three toggles persist in UserDefaults across relaunches
//   - URL scheme for automation: stayawake://activate?minutes=30,
//     stayawake://deactivate, stayawake://toggle (works from Shortcuts,
//     scripts, Raycast, Alfred…)
//   - Launch at login toggle (SMAppService, macOS 13+; older systems use
//     System Settings → Login Items) and a version line in the menu
//   - Four solid panel themes (Midnight Teal, Graphite, Daylight,
//     Amber Dusk) in a Theme submenu, persisted in UserDefaults
//   - End-of-session chime
//   - Settings window (v2.4) with four tabs — General, Appearance,
//     Shortcuts, Advanced — in StayAwake's own layout: theme swatches
//     with a live mini-timer preview, a recordable global hotkey
//     (default ⌃⌥⌘S), a default duration, activate-at-launch,
//     activate-on-left-click, pause-while-locked, and a dimmed menu
//     bar icon while off. Every setting persists and ships with a
//     sensible default pre-selected.
//   - One-click updates (v2.5): a public version feed is checked at
//     launch and on demand (menu item, plus a fifth Settings tab);
//     Install downloads the new release, verifies its SHA-256, swaps
//     the app bundle and relaunches. Power-assertion and hotkey
//     registration failures are checked and surfaced (also v2.5),
//     and battery readings come from IOKit power sources instead
//     of a pmset subprocess.
//
// Build with ./build.sh (swiftc, Xcode Command Line Tools). No dependencies.

import Cocoa
import Carbon
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement

// MARK: Pure helpers (shared with tests.swift)

/// "0:00" under an hour, "1:00:00" at an hour and beyond;
/// negative input clamps to zero.
func formatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// The custom-duration field: a positive whole number of minutes,
/// or nil for anything else (empty, zero, negative, non-numeric).
func parseCustomMinutes(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(trimmed), value > 0 else { return nil }
    return value
}

/// Battery charge as a percentage, clamped to 0...100; nil when
/// the capacity figures are unusable.
func batteryPercent(current: Int, max: Int) -> Int? {
    guard max > 0, current >= 0 else { return nil }
    return min(100, Int((Double(current) / Double(max) * 100).rounded()))
}

/// Dotted-version compare for the update feed: true when
/// `candidate` is strictly newer than `current`. Missing
/// components count as 0, so "2.5" and "2.5.0" are equal.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

final class AppDelegate: NSObject, NSApplicationDelegate, URLSessionDownloadDelegate {
    // MARK: State
    private var statusItem: NSStatusItem!
    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var startedAt: Date?
    private var deadline: Date?
    private var totalSeconds: Int = 0
    private var timer: Timer?
    private var tickCount: Int = 0

    // Lazily-cached UI helpers (v2.5.1) — updateUI() runs once a
    // second while a session is active, and building a DateFormatter
    // and re-resolving SF Symbols on every tick was the app's main
    // per-tick allocation cost. Both are now created once and reused.
    private lazy var endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
    private lazy var activeMenuBarImage: NSImage? = menuBarImage(active: true)
    private lazy var inactiveMenuBarImage: NSImage? = menuBarImage(active: false)
    /// The whole-second value tick() last painted; a tick that lands
    /// in the same second as the previous one skips the repaint.
    private var lastRenderedSecond: Int?

    // Settings — persisted to UserDefaults whenever they change, and
    // reloaded at launch, so the toggles survive quitting the app.
    private var allowDisplaySleep = false {
        didSet { UserDefaults.standard.set(allowDisplaySleep, forKey: "allowDisplaySleep") }
    }
    private var offOnBattery = false {
        didSet { UserDefaults.standard.set(offOnBattery, forKey: "offOnBattery") }
    }
    private var lowBatteryGuard = true {
        didSet { UserDefaults.standard.set(lowBatteryGuard, forKey: "lowBatteryGuard") }
    }

    // Settings-window settings (v2.4) — same persistence pattern. The
    // defaults below are what a fresh install starts with, already
    // selected; on an existing install the window simply reflects the
    // values already stored, so nothing resets.
    private var activateAtLaunch = false {
        didSet { UserDefaults.standard.set(activateAtLaunch, forKey: "activateAtLaunch") }
    }
    private var activateOnLeftClick = false {
        didSet { UserDefaults.standard.set(activateOnLeftClick, forKey: "activateOnLeftClick") }
    }
    private var showPanelOnStart = true {
        didSet { UserDefaults.standard.set(showPanelOnStart, forKey: "showPanelOnStart") }
    }
    /// Default duration in minutes; 0 means indefinitely.
    private var defaultMinutes = 0 {
        didSet { UserDefaults.standard.set(defaultMinutes, forKey: "defaultMinutes") }
    }
    private var dimIconWhenOff = true {
        didSet { UserDefaults.standard.set(dimIconWhenOff, forKey: "dimIconWhenOff") }
    }
    private var pauseOnLock = false {
        didSet { UserDefaults.standard.set(pauseOnLock, forKey: "pauseOnLock") }
    }
    private var chimeOnEnd = true {
        didSet { UserDefaults.standard.set(chimeOnEnd, forKey: "chimeOnEnd") }
    }
    /// Global hotkey: Carbon key code + Carbon modifier mask.
    /// Default is ⌃⌥⌘S (key code 1, modifiers 4096+2048+256 = 6400).
    /// A key code of -1 means no shortcut is set.
    private var hotkeyKeyCode = 1 {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }
    private var hotkeyModifiers = 6400 {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    // MARK: Panel themes
    // The mini timer used to be a translucent HUD with white text, which
    // washed out to near-invisible in light surroundings. Themes are now
    // solid, explicit colour sets — readable in any environment — and the
    // chosen one persists like the other settings.
    private struct PanelTheme {
        let name: String
        let background: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
        let accent: NSColor
        let track: NSColor
        let buttonBackground: NSColor
        let buttonText: NSColor
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private let themes: [PanelTheme] = [
        PanelTheme(name: "Midnight Teal",           // default — matches the app icon
                   background: rgb(0.05, 0.20, 0.20),
                   primaryText: .white,
                   secondaryText: rgb(1, 1, 1, 0.65),
                   accent: rgb(0.96, 0.65, 0.14),   // amber
                   track: rgb(1, 1, 1, 0.18),
                   buttonBackground: rgb(1, 1, 1, 0.24),
                   buttonText: .white),
        PanelTheme(name: "Graphite",
                   background: rgb(0.11, 0.11, 0.12),
                   primaryText: .white,
                   secondaryText: rgb(1, 1, 1, 0.60),
                   accent: rgb(0.37, 0.36, 0.90),   // indigo
                   track: rgb(1, 1, 1, 0.16),
                   buttonBackground: rgb(1, 1, 1, 0.22),
                   buttonText: .white),
        PanelTheme(name: "Daylight",
                   background: rgb(0.98, 0.97, 0.94),
                   primaryText: rgb(0.10, 0.10, 0.10),
                   secondaryText: rgb(0, 0, 0, 0.55),
                   accent: rgb(0.05, 0.45, 0.44),   // teal
                   track: rgb(0, 0, 0, 0.10),
                   buttonBackground: rgb(0, 0, 0, 0.12),
                   buttonText: rgb(0.10, 0.10, 0.10)),
        PanelTheme(name: "Amber Dusk",
                   background: rgb(0.17, 0.10, 0.03),
                   primaryText: rgb(1.0, 0.96, 0.91),
                   secondaryText: rgb(1, 0.96, 0.91, 0.60),
                   accent: rgb(1.0, 0.70, 0.25),    // warm amber
                   track: rgb(1, 1, 1, 0.15),
                   buttonBackground: rgb(1, 1, 1, 0.20),
                   buttonText: rgb(1.0, 0.96, 0.91)),
    ]

    private var themeName = "Midnight Teal" {
        didSet { UserDefaults.standard.set(themeName, forKey: "panelTheme") }
    }
    private var currentTheme: PanelTheme {
        themes.first(where: { $0.name == themeName }) ?? themes[0]
    }

    var isActive: Bool { assertionID != 0 }
    var isIndefinite: Bool { isActive && deadline == nil }
    /// A session exists (started, not yet deactivated) — unlike isActive
    /// this stays true while paused for a locked screen, when the power
    /// assertions are temporarily released.
    var hasSession: Bool { startedAt != nil }

    // MARK: Update checker + one-click install (v2.5)

    // Ported from ClipKeep's updater: a tiny public gist carries
    // the latest version, its release-zip URL and the zip's
    // SHA-256; the installer verifies the checksum before swapping
    // the bundle. The feed check is the only network request the
    // app ever makes, and it sends nothing about the user.
    static let updateFeedURL = "https://gist.githubusercontent.com/femisowems/4ad10fc3c50a2cf11fc922d1893fbd78/raw/stayawake-version.json"
    private var availableUpdate: (version: String, url: String, sha256: String?)?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var pendingUpdateVersion: String?
    private var pendingUpdateSHA256: String?
    private var updateWindow: NSPanel?
    private var updateLabel: NSTextField?
    private var updateBar: NSProgressIndicator?
    private var updateCloseButton: NSButton?
    private var statusFlashGeneration = 0
    private var updateStatusText = "Updates are checked automatically at launch."
    private var updateSnoozedUntil: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "updateSnoozedUntil")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "updateSnoozedUntil") }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.5.1"
    }

    func checkForUpdate(manual: Bool = false) {
        guard let feed = URL(string: Self.updateFeedURL) else { return }
        var request = URLRequest(url: feed)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      // "latest" is the canonical key; "version" is
                      // accepted too (a feed published with only the
                      // wrong key once broke ClipKeep's checks).
                      let latest = (obj["latest"] as? String) ?? (obj["version"] as? String),
                      let url = obj["url"] as? String, !url.isEmpty
                else {
                    if manual {
                        self.updateStatusText = "Couldn't check for updates just now."
                        self.refreshSettingsControls()
                        let alert = NSAlert()
                        alert.messageText = "Couldn't check for updates"
                        alert.informativeText = "The version feed couldn't be reached. Check your connection and try again."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
                let sha = obj["sha256"] as? String
                if isNewerVersion(latest, than: self.currentVersion) {
                    self.availableUpdate = (latest, url, sha)
                    self.updateStatusText = "StayAwake \(latest) is available — choose Install to update."
                    let dismissed = UserDefaults.standard.string(forKey: "dismissedUpdateVersion") == latest
                    let snoozed = Date() < self.updateSnoozedUntil
                    if manual || (!dismissed && !snoozed) { self.promptForUpdate() }
                } else {
                    self.availableUpdate = nil
                    self.updateStatusText = "You're up to date (StayAwake \(self.currentVersion))."
                    if manual { self.flashUpToDate() }
                }
                self.refreshSettingsControls()
            }
        }.resume()
    }

    private func promptForUpdate() {
        guard let upd = availableUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "StayAwake \(upd.version) is available"
        alert.informativeText = "You're running StayAwake \(currentVersion). Install downloads the update, verifies it against the feed's checksum, swaps the app and relaunches it — your settings carry over."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startUpdateDownload()
        case .alertSecondButtonReturn:
            updateSnoozedUntil = Date().addingTimeInterval(24 * 3600)
        default:
            UserDefaults.standard.set(upd.version, forKey: "dismissedUpdateVersion")
        }
    }

    /// A manual check that finds nothing still answers: the menu
    /// bar title flashes "✓ Up to date" for a couple of seconds,
    /// then the normal display restores itself.
    private func flashUpToDate() {
        guard let button = statusItem?.button else { return }
        statusFlashGeneration += 1
        let generation = statusFlashGeneration
        button.image = nil
        button.title = "✓ Up to date"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.statusFlashGeneration == generation else { return }
            self.updateUI()
        }
    }

    @objc private func updateCheckClicked() { checkForUpdate(manual: true) }

    private func startUpdateDownload() {
        guard downloadTask == nil,
              let upd = availableUpdate, let url = URL(string: upd.url) else { return }
        pendingUpdateVersion = upd.version
        pendingUpdateSHA256 = upd.sha256
        showUpdatePanel(message: "Downloading StayAwake \(upd.version)…")
        updateBar?.isIndeterminate = false
        updateBar?.doubleValue = 0
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession = session
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    private func showUpdatePanel(message: String) {
        if updateWindow == nil {
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 118),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "StayAwake Update"
            w.level = .floating
            w.isReleasedWhenClosed = false
            let label = NSTextField(wrappingLabelWithString: message)
            label.frame = NSRect(x: 20, y: 64, width: 320, height: 38)
            w.contentView?.addSubview(label)
            let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 38, width: 320, height: 16))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 100
            w.contentView?.addSubview(bar)
            let close = NSButton(title: "Close", target: self, action: #selector(closeUpdatePanel))
            close.frame = NSRect(x: 268, y: 6, width: 72, height: 26)
            close.bezelStyle = .rounded
            close.isHidden = true
            w.contentView?.addSubview(close)
            updateWindow = w
            updateLabel = label
            updateBar = bar
            updateCloseButton = close
        }
        updateLabel?.stringValue = message
        updateBar?.isHidden = false
        updateCloseButton?.isHidden = true
        updateWindow?.center()
        updateWindow?.orderFrontRegardless()
    }

    @objc private func closeUpdatePanel() { updateWindow?.orderOut(nil) }

    private func updateFailed(_ message: String) {
        downloadTask = nil
        downloadSession = nil
        if updateWindow == nil { showUpdatePanel(message: "") }
        updateLabel?.stringValue = "Update failed: \(message)"
        updateBar?.isHidden = true
        updateCloseButton?.isHidden = false
        updateStatusText = "The last update attempt failed: \(message)"
        refreshSettingsControls()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        updateBar?.isIndeterminate = false
        updateBar?.doubleValue = pct * 100
        updateLabel?.stringValue = "Downloading StayAwake \(pendingUpdateVersion ?? "")… \(Int(pct * 100))%"
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let version = pendingUpdateVersion ?? "update"
        updateLabel?.stringValue = "Installing StayAwake \(version)…"
        updateBar?.isIndeterminate = true
        do {
            try installDownloadedUpdate(zipAt: location, version: version, expectedSHA256: pendingUpdateSHA256)
        } catch {
            updateFailed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { updateFailed(error.localizedDescription) }
        if downloadTask != nil {
            downloadTask = nil
            downloadSession = nil
        }
    }

    // SHA-256 of a file via the system shasum tool — the app
    // already shells out to ditto for the unzip, so this adds no
    // new linked dependency. Lowercase hex, or nil on failure.
    private func sha256(ofFile url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: " ").first.map(String.init)?.lowercased()
    }

    // Replace the running app with the downloaded one: unzip to
    // a staging folder, then a detached script waits for this
    // process to exit, swaps the bundles (keeping a backup until
    // the new one is in place), and relaunches. When the feed
    // published a sha256 for this release, the download is
    // verified against it first and a mismatch aborts the
    // install before anything is unzipped or swapped.
    private func installDownloadedUpdate(zipAt zipURL: URL, version: String, expectedSHA256: String?) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("stayawake-update-\(version)")
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        // The download task's temp file vanishes when this
        // delegate returns, so move it into staging first.
        let stagedZip = stage.appendingPathComponent("update.zip")
        try fm.copyItem(at: zipURL, to: stagedZip)
        if let expected = expectedSHA256, !expected.isEmpty {
            guard let actual = sha256(ofFile: stagedZip), actual == expected.lowercased() else {
                throw NSError(domain: "StayAwakeUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "checksum mismatch — the download was discarded"])
            }
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", stagedZip.path, stage.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "StayAwakeUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't unzip the download"])
        }
        let newApp = stage.appendingPathComponent("StayAwake.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw NSError(domain: "StayAwakeUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "the download didn't contain the app"])
        }
        let current = Bundle.main.bundlePath
        let backup = current + ".bak"
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(backup)"
        mv "\(current)" "\(backup)"
        if mv "\(newApp.path)" "\(current)"; then
          rm -rf "\(backup)"
          open "\(current)"
        else
          mv "\(backup)" "\(current)"
          open "\(newApp.path)"
        fi
        """
        let scriptURL = stage.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [scriptURL.path]
        try run.run()
        NSApp.terminate(nil)
    }

    // MARK: Settings window / hotkey / lock-pause state
    private var mainMenu: NSMenu?
    private var pausedForLock = false
    private var lockPausedAt: Date?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hotkeyFailureReported = false
    private var settingsWindow: NSWindow?
    private var genLaunchLoginBox: NSButton?
    private var genActivateAtLaunchBox: NSButton?
    private var genLeftClickBox: NSButton?
    private var genShowPanelBox: NSButton?
    private var advDurationPopup: NSPopUpButton?
    private var advDisplaySleepBox: NSButton?
    private var advPauseLockBox: NSButton?
    private var advOffBatteryBox: NSButton?
    private var advLowBatteryBox: NSButton?
    private var advChimeBox: NSButton?
    private var updatesStatusLabel: NSTextField?
    private var appDimIconBox: NSButton?
    private var swatchButtons: [NSButton] = []
    private var previewBG: NSView?
    private var previewTitle: NSTextField?
    private var previewTime: NSTextField?
    private var previewStatus: NSTextField?
    private var previewTrack: NSView?
    private var previewFill: NSView?
    private var previewPills: [(NSView, NSTextField)] = []
    private var shortcutButton: NSButton?
    private var recordingMonitor: Any?
    private let durationChoices: [(String, Int)] = [
        ("Indefinitely", 0), ("15 minutes", 15), ("30 minutes", 30),
        ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480),
    ]

    // MARK: Mini timer panel UI
    private var panel: NSPanel?
    private var panelView: NSView?
    private var titleLabel: NSTextField?
    private var timeLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var endLabel: NSTextField?
    private var progressTrack: NSView?
    private var progressFill: NSView?
    private var panelButtons: [NSButton] = []

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore the saved toggles (lowBatteryGuard defaults to on, so
        // only override it when a value was actually stored).
        let defaults = UserDefaults.standard
        allowDisplaySleep = defaults.bool(forKey: "allowDisplaySleep")
        offOnBattery = defaults.bool(forKey: "offOnBattery")
        if defaults.object(forKey: "lowBatteryGuard") != nil {
            lowBatteryGuard = defaults.bool(forKey: "lowBatteryGuard")
        }
        if let savedTheme = defaults.string(forKey: "panelTheme"),
           themes.contains(where: { $0.name == savedTheme }) {
            themeName = savedTheme
        }
        // v2.4 settings: plain bools default to false; the ones whose
        // default is true (and the hotkey) only override when stored.
        activateAtLaunch = defaults.bool(forKey: "activateAtLaunch")
        activateOnLeftClick = defaults.bool(forKey: "activateOnLeftClick")
        pauseOnLock = defaults.bool(forKey: "pauseOnLock")
        defaultMinutes = defaults.integer(forKey: "defaultMinutes")
        if defaults.object(forKey: "showPanelOnStart") != nil {
            showPanelOnStart = defaults.bool(forKey: "showPanelOnStart")
        }
        if defaults.object(forKey: "dimIconWhenOff") != nil {
            dimIconWhenOff = defaults.bool(forKey: "dimIconWhenOff")
        }
        if defaults.object(forKey: "chimeOnEnd") != nil {
            chimeOnEnd = defaults.bool(forKey: "chimeOnEnd")
        }
        if defaults.object(forKey: "hotkeyKeyCode") != nil {
            hotkeyKeyCode = defaults.integer(forKey: "hotkeyKeyCode")
        }
        if defaults.object(forKey: "hotkeyModifiers") != nil {
            hotkeyModifiers = defaults.integer(forKey: "hotkeyModifiers")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        // Clicks are handled manually so "Activate on left-click" can
        // toggle instead of opening the menu (right-click always opens
        // the menu; see statusItemClicked).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateUI()
        registerHotkey()
        // Pause-while-locked observers.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // No tick timer is created here (v2.5.1): the timer is
        // scoped to the session — activate() starts it and
        // deactivate() stops it — so an idle, off StayAwake no
        // longer wakes the run loop twice a second for nothing.
        if activateAtLaunch {
            activate(minutes: defaultMinutes)
        }
        // Silent update check shortly after launch (v2.5); the
        // prompt itself is suppressed while snoozed or dismissed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkForUpdate()
        }
    }

    // MARK: URL scheme — stayawake://activate?minutes=30 / deactivate / toggle
    // Registered in Info.plist by build.sh. Lets Shortcuts (via "Open
    // URLs"), shell scripts, Raycast, Alfred etc. drive the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleURL(url) }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "stayawake" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let minutes = components?.queryItems?
            .first(where: { $0.name == "minutes" })?.value.flatMap { Int($0) }
        switch url.host {
        case "activate":
            activate(minutes: minutes ?? 0) // no minutes = indefinite
        case "deactivate", "stop":
            deactivate()
        case "toggle":
            if isActive { deactivate() } else { activate(minutes: minutes ?? 0) }
        default:
            break // stayawake:// on its own just launches the app
        }
    }

    // MARK: Power assertions
    /// Creates the sleep-prevention assertions. Returns false when
    /// macOS refuses the system assertion — a session cannot work
    /// without it, and since v2.5 the result is checked and
    /// surfaced instead of silently leaving the Mac able to sleep
    /// while the UI claims a session is running.
    @discardableResult
    private func createAssertions() -> Bool {
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAwake is keeping this Mac awake" as CFString,
            &assertionID)
        guard systemResult == kIOReturnSuccess else {
            assertionID = 0
            NSLog("StayAwake: system-sleep assertion failed (IOPM error \(systemResult))")
            return false
        }
        if !allowDisplaySleep {
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "StayAwake is keeping the display awake" as CFString,
                &displayAssertionID)
            if displayResult != kIOReturnSuccess {
                // The system stays awake regardless; only the
                // display guarantee is lost, so log it and go on.
                displayAssertionID = 0
                NSLog("StayAwake: display-sleep assertion failed (IOPM error \(displayResult))")
            }
        }
        return true
    }

    /// Tells the user a session couldn't (or can no longer) hold
    /// the Mac awake, and stops the session so the UI never claims
    /// otherwise.
    private func sleepAssertionFailed() {
        deactivate()
        let alert = NSAlert()
        alert.messageText = "StayAwake couldn't keep this Mac awake"
        alert.informativeText = "macOS refused the sleep-prevention request, so the session has been stopped. Please try again — if it keeps happening, restarting the Mac usually clears it."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func releaseAssertions() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID); displayAssertionID = 0 }
    }

    // MARK: Session control
    /// Starts the once-a-second session tick (v2.5.1). The display
    /// only ever shows whole seconds, so a 1s interval loses
    /// nothing over the old 0.5s one and halves the wake-ups; the
    /// tolerance lets the run loop coalesce the fire with other
    /// timers. Guarded so re-activating mid-session never stacks
    /// a second timer.
    private func startTickTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.1
        timer = t
    }

    private func stopTickTimer() {
        timer?.invalidate()
        timer = nil
        tickCount = 0
        lastRenderedSecond = nil
    }

    func activate(minutes: Int) {
        releaseAssertions()
        pausedForLock = false
        lockPausedAt = nil
        guard createAssertions() else { sleepAssertionFailed(); return }
        startedAt = Date()
        if minutes > 0 {
            totalSeconds = minutes * 60
            deadline = Date().addingTimeInterval(TimeInterval(totalSeconds))
        } else {
            totalSeconds = 0
            deadline = nil
        }
        if showPanelOnStart { showPanel() }
        startTickTimer()
        buildMenu()
        updateUI()
    }

    func deactivate(chime: Bool = false) {
        stopTickTimer()
        releaseAssertions()
        pausedForLock = false
        lockPausedAt = nil
        startedAt = nil
        deadline = nil
        totalSeconds = 0
        panel?.orderOut(nil)
        if chime { NSSound(named: NSSound.Name("Glass"))?.play() }
        buildMenu()
        updateUI()
    }

    /// Toggle using the default duration — the hotkey and the
    /// activate-on-left-click behaviour both go through here.
    func toggleDefault() {
        if hasSession { deactivate() } else { activate(minutes: defaultMinutes) }
    }

    @objc func add15() {
        guard isActive, let current = deadline else { return }
        deadline = current.addingTimeInterval(15 * 60)
        totalSeconds += 15 * 60
        updateUI()
    }

    private func tick() {
        guard isActive else { return }
        tickCount += 1
        if let deadline, Date() >= deadline {
            deactivate(chime: chimeOnEnd)
            return
        }
        // Battery checks roughly every 10 seconds (10 ticks at 1s).
        if tickCount % 10 == 0 {
            let (percent, onBattery) = batteryInfo()
            if offOnBattery && onBattery {
                deactivate()
                return
            }
            if lowBatteryGuard && onBattery, let percent, percent <= 20 {
                deactivate()
                return
            }
        }
        // Repaint only when the displayed whole second has changed
        // (v2.5.1) — the countdown renders whole seconds, so a tick
        // that lands in the same second has nothing new to draw.
        let displaySecond: Int
        if let deadline {
            displaySecond = Int(deadline.timeIntervalSinceNow)
        } else if let startedAt {
            displaySecond = Int(Date().timeIntervalSince(startedAt))
        } else {
            displaySecond = 0
        }
        if displaySecond != lastRenderedSecond {
            lastRenderedSecond = displaySecond
            updateUI()
        }
    }

    /// Returns (percent charged if readable, true if currently
    /// drawing from battery). Reads the power-source snapshot from
    /// IOKit (v2.5) — the old version spawned /usr/bin/pmset and
    /// blocked on it every 10 seconds. A Mac with no battery (a
    /// desktop) reports (nil, false).
    private func batteryInfo() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int
            else { continue }
            let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (batteryPercent(current: current, max: maxCapacity), onBattery)
        }
        return (nil, false)
    }

    // MARK: Floating mini timer panel (the "always on top" part)
    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: 320, height: 188)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered,
                        defer: false)
        p.level = .floating                                   // always on top
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true                  // drag it anywhere
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        // Solid themed surface (replaces the old translucent HUD view,
        // whose white text washed out against light backgrounds).
        let effect = NSView(frame: rect)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        p.contentView = effect
        panelView = effect

        func label(_ frame: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
            let field = NSTextField(frame: frame)
            field.isEditable = false
            field.isBezeled = false
            field.drawsBackground = false
            field.textColor = color
            field.font = .systemFont(ofSize: size, weight: weight)
            effect.addSubview(field)
            return field
        }

        let title = label(NSRect(x: 16, y: 156, width: 220, height: 20),
                          size: 13, weight: .semibold, color: .white)
        title.stringValue = "☕ StayAwake"
        titleLabel = title

        let time = label(NSRect(x: 16, y: 108, width: 288, height: 42),
                         size: 30, weight: .bold, color: .white)
        time.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        time.stringValue = "0:00"
        timeLabel = time

        statusLabel = label(NSRect(x: 16, y: 90, width: 288, height: 16),
                            size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.65))
        endLabel = label(NSRect(x: 16, y: 48, width: 288, height: 16),
                         size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.65))

        // Custom progress bar (track + fill) so the theme controls its
        // colours exactly — NSProgressIndicator can't be tinted reliably.
        let track = NSView(frame: NSRect(x: 16, y: 70, width: 288, height: 10))
        track.wantsLayer = true
        track.layer?.cornerRadius = 5
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 10))
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 5
        track.addSubview(fill)
        effect.addSubview(track)
        progressTrack = track
        progressFill = fill

        func button(_ title: String, x: CGFloat, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 12, width: 64, height: 26)
            b.bezelStyle = .rounded
            b.isBordered = true
            effect.addSubview(b)
            panelButtons.append(b)
            return b
        }
        _ = button("Hide", x: 16, action: #selector(hidePanel))
        _ = button("+15 min", x: 168, action: #selector(add15Clicked))
        _ = button("Stop", x: 240, action: #selector(stopClicked))
        applyTheme()

        // Default spot: top-right of the main screen, below the menu bar.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.maxX - 336, y: visible.maxY - 204))
        }
        panel = p
    }

    /// Repaint the whole panel from the current theme.
    private func applyTheme() {
        let theme = currentTheme
        panelView?.layer?.backgroundColor = theme.background.cgColor
        titleLabel?.textColor = theme.primaryText
        timeLabel?.textColor = theme.primaryText
        statusLabel?.textColor = theme.secondaryText
        endLabel?.textColor = theme.secondaryText
        progressTrack?.layer?.backgroundColor = theme.track.cgColor
        progressFill?.layer?.backgroundColor = theme.accent.cgColor
        for button in panelButtons {
            button.bezelColor = theme.buttonBackground
            // contentTintColor alone does NOT recolor a push button's
            // title — v2.2's dark themes shipped black labels on dark
            // pills because of this. Set the title colour explicitly
            // via attributedTitle, which the button cell always honours.
            let title = button.title
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: theme.buttonText,
                             .font: NSFont.systemFont(ofSize: 13)])
            button.contentTintColor = theme.buttonText
        }
    }

    private func setProgress(_ fraction: Double) {
        guard let fill = progressFill, let track = progressTrack else { return }
        let clamped = min(1, max(0, fraction))
        fill.frame = NSRect(x: 0, y: 0, width: track.frame.width * CGFloat(clamped), height: 10)
    }

    private func showPanel() {
        makePanelIfNeeded()
        panel?.orderFrontRegardless()
    }

    @objc private func hidePanel() { panel?.orderOut(nil) }
    @objc private func add15Clicked() { add15() }
    @objc private func stopClicked() { deactivate() }

    // MARK: UI updates
    private func format(_ seconds: Int) -> String { formatDuration(seconds) }

    /// Native menu bar glyph (SF Symbol, template-rendered so it adapts
    /// to light/dark menu bars) instead of an emoji. Falls back to the
    /// emoji title if the symbol is unavailable.
    private func menuBarImage(active: Bool) -> NSImage? {
        let name = active ? "cup.and.saucer.fill" : "moon.zzz.fill"
        let image = NSImage(systemSymbolName: name,
                            accessibilityDescription: active ? "StayAwake on" : "StayAwake off")
        image?.isTemplate = true
        return image
    }

    private func updateUI() {
        guard let button = statusItem?.button else { return }
        if pausedForLock && hasSession {
            // Frozen display while the screen is locked: the countdown
            // resumes from this exact point on unlock.
            button.alphaValue = 1.0
            button.image = activeMenuBarImage
            button.imagePosition = .imageLeading
            // Panel labels only repaint while the panel is on
            // screen (v2.5.1); the menu bar updates regardless.
            let panelVisible = panel?.isVisible == true
            if let deadline {
                let frozenAt = lockPausedAt ?? Date()
                let left = Int(deadline.timeIntervalSince(frozenAt))
                button.title = button.image == nil ? "☕ " + format(left) : format(left)
                if panelVisible { timeLabel?.stringValue = format(left) }
            } else {
                button.title = button.image == nil ? "☕ ∞" : "∞"
                let elapsed = startedAt.map { Int((lockPausedAt ?? Date()).timeIntervalSince($0)) } ?? 0
                if panelVisible { timeLabel?.stringValue = format(elapsed) }
            }
            if panelVisible {
                statusLabel?.stringValue = "Paused — screen is locked"
                endLabel?.stringValue = "Resumes when you unlock"
            }
            button.toolTip = "StayAwake is paused (screen locked)"
            return
        }
        if !isActive {
            if let image = inactiveMenuBarImage {
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = "💤"
            }
            button.alphaValue = dimIconWhenOff ? 0.45 : 1.0
            button.toolTip = "StayAwake is off"
            return
        }
        button.alphaValue = 1.0
        button.image = activeMenuBarImage
        button.imagePosition = .imageLeading
        // Panel labels/progress only repaint while the panel is on
        // screen (v2.5.1); the menu bar updates regardless.
        let panelVisible = panel?.isVisible == true
        if let deadline {
            let left = Int(deadline.timeIntervalSinceNow)
            button.title = button.image == nil ? "☕ " + format(left) : format(left)
            if panelVisible {
                timeLabel?.stringValue = format(left)
                statusLabel?.stringValue = "ON — holding screen awake"
                endLabel?.stringValue = "Ends " + endTimeFormatter.string(from: deadline)
                if totalSeconds > 0 {
                    let elapsed = totalSeconds - left
                    setProgress(Double(elapsed) / Double(totalSeconds))
                }
            }
        } else {
            button.title = button.image == nil ? "☕ ∞" : "∞"
            if panelVisible {
                let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
                timeLabel?.stringValue = format(elapsed)
                statusLabel?.stringValue = "ON — runs until you stop it"
                endLabel?.stringValue = "No end time"
                setProgress(1)
            }
        }
        button.toolTip = "StayAwake is on"
    }

    // MARK: Menu
    private func buildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: isActive ? "StayAwake is ON" : "StayAwake is OFF",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let versionItem = NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let presets: [(String, Int)] = [
            ("Activate for 15 minutes", 15), ("Activate for 30 minutes", 30),
            ("Activate for 1 hour", 60), ("Activate for 2 hours", 120),
            ("Activate for 4 hours", 240), ("Activate for 8 hours", 480),
            ("Activate indefinitely", 0),
        ]
        for (title, mins) in presets {
            let item = NSMenuItem(title: title, action: #selector(presetClicked(_:)), keyEquivalent: "")
            item.representedObject = mins
            item.target = self
            menu.addItem(item)
        }
        let custom = NSMenuItem(title: "Activate for custom minutes…",
                                action: #selector(customClicked), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show mini timer",
                              action: #selector(showPanelClicked), keyEquivalent: "")
        show.target = self
        show.isEnabled = isActive
        menu.addItem(show)

        let add = NSMenuItem(title: "Add 15 minutes", action: #selector(add15Clicked), keyEquivalent: "")
        add.target = self
        add.isEnabled = isActive && !isIndefinite
        menu.addItem(add)

        let stop = NSMenuItem(title: "Deactivate", action: #selector(stopClicked), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = isActive
        menu.addItem(stop)
        menu.addItem(.separator())

        let disp = NSMenuItem(title: "Allow display to sleep while awake",
                              action: #selector(toggleDisplaySleep), keyEquivalent: "")
        disp.target = self
        disp.state = allowDisplaySleep ? .on : .off
        menu.addItem(disp)

        let batt = NSMenuItem(title: "Deactivate when switching to battery",
                              action: #selector(toggleOffOnBattery), keyEquivalent: "")
        batt.target = self
        batt.state = offOnBattery ? .on : .off
        menu.addItem(batt)

        let guardItem = NSMenuItem(title: "Stop at 20% battery",
                                   action: #selector(toggleLowBatteryGuard), keyEquivalent: "")
        guardItem.target = self
        guardItem.state = lowBatteryGuard ? .on : .off
        menu.addItem(guardItem)

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: #selector(themeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.name
            item.state = theme.name == themeName ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            // SMAppService needs macOS 13; older systems add the app via
            // System Settings → General → Login Items instead.
            login.isEnabled = false
        }
        menu.addItem(login)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(updateCheckClicked), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit StayAwake", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // The menu is no longer attached to the status item full-time:
        // statusItemClicked attaches it on demand so left-click can
        // toggle instead when that setting is on.
        mainMenu = menu
        refreshSettingsControls()
    }

    @objc private func presetClicked(_ sender: NSMenuItem) {
        activate(minutes: (sender.representedObject as? Int) ?? 60)
    }

    @objc private func customClicked() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Custom duration"
        alert.informativeText = "Keep this Mac awake for how many minutes?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "45"
        alert.accessoryView = field
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let mins = parseCustomMinutes(field.stringValue) {
            activate(minutes: mins)
        }
    }

    @objc private func showPanelClicked() { showPanel() }

    @objc private func toggleDisplaySleep() {
        allowDisplaySleep.toggle()
        if isActive {
            // Re-create assertions under the new setting, keeping the session.
            releaseAssertions()
            if !createAssertions() { sleepAssertionFailed() }
        }
        buildMenu()
    }

    @objc private func toggleOffOnBattery() { offOnBattery.toggle(); buildMenu() }
    @objc private func toggleLowBatteryGuard() { lowBatteryGuard.toggle(); buildMenu() }

    @objc private func themeClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              themes.contains(where: { $0.name == name }) else { return }
        themeName = name
        applyTheme()
        buildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                // Registration fails when the app isn't running from a
                // stable location (e.g. not yet in /Applications). The
                // menu is rebuilt below, so its checkmark always reflects
                // the service's real status.
            }
        }
        buildMenu()
    }
    @objc private func quitClicked() { deactivate(); NSApp.terminate(nil) }

    // MARK: Status item clicks
    /// Left-click toggles (with the default duration) when "Activate on
    /// left-click" is on; otherwise — and always on right-click or
    /// Control-click — the menu opens.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseDown
            || event.modifierFlags.contains(.control)
            || !activateOnLeftClick
        if wantsMenu {
            statusItem.menu = mainMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleDefault()
        }
    }

    // MARK: Global hotkey (Carbon)
    private func registerHotkey() {
        unregisterHotkey()
        guard hotkeyKeyCode >= 0 else { return }
        if hotKeyHandlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<AppDelegate>.fromOpaque(userData)
                    .takeUnretainedValue().hotkeyPressed()
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
            if handlerStatus != noErr {
                NSLog("StayAwake: hotkey event handler install failed (OSStatus \(handlerStatus))")
            }
        }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x5341574B // 'SAWK'
        hotKeyID.id = 1
        let status = RegisterEventHotKey(UInt32(hotkeyKeyCode), UInt32(hotkeyModifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        // Registration results are checked since v2.5 (the same
        // fix ClipKeep shipped in its v2.16.0): a shortcut another
        // app already owns fails here, and the user hears about it
        // once instead of the hotkey silently doing nothing.
        if status == noErr {
            hotkeyFailureReported = false
        } else {
            hotKeyRef = nil
            NSLog("StayAwake: hotkey registration failed (OSStatus \(status))")
            if !hotkeyFailureReported {
                hotkeyFailureReported = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let alert = NSAlert()
                    alert.messageText = "Your StayAwake shortcut couldn't be registered"
                    alert.informativeText = "The shortcut \(self.shortcutDisplayString() ?? "") may already be used by another app. StayAwake still works from its menu — you can pick a different shortcut in Settings → Shortcuts."
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    private func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    func hotkeyPressed() { toggleDefault() }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.control) { m |= 4096 } // controlKey
        if flags.contains(.option) { m |= 2048 }  // optionKey
        if flags.contains(.shift) { m |= 512 }    // shiftKey
        if flags.contains(.command) { m |= 256 }  // cmdKey
        return m
    }

    private let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
        51: "⌫", 53: "Esc",
    ]

    private func shortcutDisplayString() -> String? {
        guard hotkeyKeyCode >= 0 else { return nil }
        var s = ""
        if hotkeyModifiers & 4096 != 0 { s += "⌃" }
        if hotkeyModifiers & 2048 != 0 { s += "⌥" }
        if hotkeyModifiers & 512 != 0 { s += "⇧" }
        if hotkeyModifiers & 256 != 0 { s += "⌘" }
        s += keyNames[hotkeyKeyCode] ?? "Key \(hotkeyKeyCode)"
        return s
    }

    // MARK: Pause while screen is locked
    @objc private func screenLocked() {
        guard pauseOnLock, hasSession, !pausedForLock else { return }
        pausedForLock = true
        lockPausedAt = Date()
        releaseAssertions()
        updateUI()
    }

    @objc private func screenUnlocked() {
        guard pausedForLock else { return }
        pausedForLock = false
        let lockedFor = lockPausedAt.map { Date().timeIntervalSince($0) } ?? 0
        lockPausedAt = nil
        if hasSession {
            // Freeze-frame the session across the locked interval.
            if let d = deadline { deadline = d.addingTimeInterval(lockedFor) }
            if let s = startedAt { startedAt = s.addingTimeInterval(lockedFor) }
            if !createAssertions() { sleepAssertionFailed() }
        }
        updateUI()
    }

    // MARK: Settings window
    @objc private func showSettings() {
        makeSettingsWindowIfNeeded()
        refreshSettingsControls()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowIfNeeded() {
        guard settingsWindow == nil else { return }

        func checkbox(_ title: String, _ y: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: action)
            b.frame = NSRect(x: 24, y: y, width: 410, height: 20)
            return b
        }
        func caption(_ text: String, _ y: CGFloat, _ height: CGFloat = 16) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.frame = NSRect(x: 24, y: y, width: 404, height: height)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            return f
        }
        func tab(_ label: String, _ symbol: String, _ view: NSView) -> NSTabViewItem {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            view.frame = NSRect(x: 0, y: 0, width: 452, height: 300)
            view.autoresizingMask = [.width, .height]
            item.view = view
            return item
        }

        // — General —
        let general = NSView()
        genLaunchLoginBox = checkbox("Launch at login", 232, #selector(toggleLaunchAtLogin))
        genActivateAtLaunchBox = checkbox("Activate at launch", 202, #selector(genActivateAtLaunchToggled(_:)))
        genLeftClickBox = checkbox("Activate on left-click", 172, #selector(genLeftClickToggled(_:)))
        genShowPanelBox = checkbox("Show the mini timer when a session starts", 112, #selector(genShowPanelToggled(_:)))
        general.addSubview(genLaunchLoginBox!)
        general.addSubview(genActivateAtLaunchBox!)
        general.addSubview(genLeftClickBox!)
        general.addSubview(caption("With left-click activation on, a right-click (or Control-click) opens the menu instead.", 142, 26))
        general.addSubview(genShowPanelBox!)

        // — Appearance —
        let appearance = NSView()
        let themeLabel = NSTextField(labelWithString: "Mini timer theme:")
        themeLabel.frame = NSRect(x: 24, y: 248, width: 300, height: 18)
        themeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appearance.addSubview(themeLabel)
        swatchButtons = []
        for (i, theme) in themes.enumerated() {
            let b = NSButton(title: theme.name, target: self, action: #selector(swatchClicked(_:)))
            b.frame = NSRect(x: 24 + CGFloat(i) * 106, y: 210, width: 100, height: 34)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.bezelColor = theme.background
            b.attributedTitle = NSAttributedString(
                string: theme.name,
                attributes: [.foregroundColor: theme.primaryText,
                             .font: NSFont.systemFont(ofSize: 12)])
            b.tag = i
            swatchButtons.append(b)
            appearance.addSubview(b)
        }
        let bg = NSView(frame: NSRect(x: 66, y: 52, width: 320, height: 140))
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        let pTitle = NSTextField(labelWithString: "☕ StayAwake")
        pTitle.frame = NSRect(x: 16, y: 112, width: 220, height: 18)
        pTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        bg.addSubview(pTitle)
        let pTime = NSTextField(labelWithString: "24:59")
        pTime.frame = NSRect(x: 16, y: 76, width: 220, height: 32)
        pTime.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        bg.addSubview(pTime)
        let pStatus = NSTextField(labelWithString: "ON — holding screen awake")
        pStatus.frame = NSRect(x: 16, y: 60, width: 280, height: 14)
        pStatus.font = .systemFont(ofSize: 11)
        bg.addSubview(pStatus)
        let pTrack = NSView(frame: NSRect(x: 16, y: 42, width: 288, height: 8))
        pTrack.wantsLayer = true
        pTrack.layer?.cornerRadius = 4
        let pFill = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 8))
        pFill.wantsLayer = true
        pFill.layer?.cornerRadius = 4
        pTrack.addSubview(pFill)
        bg.addSubview(pTrack)
        var pills: [(NSView, NSTextField)] = []
        for (title, x, w) in [("Hide", 16.0, 64.0), ("+15 min", 168.0, 64.0), ("Stop", 240.0, 64.0)] {
            let pill = NSView(frame: NSRect(x: x, y: 10, width: w, height: 22))
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 6
            let lab = NSTextField(labelWithString: title)
            lab.frame = NSRect(x: 0, y: 3, width: w, height: 16)
            lab.alignment = .center
            lab.font = .systemFont(ofSize: 11)
            pill.addSubview(lab)
            bg.addSubview(pill)
            pills.append((pill, lab))
        }
        appearance.addSubview(bg)
        previewBG = bg
        previewTitle = pTitle
        previewTime = pTime
        previewStatus = pStatus
        previewTrack = pTrack
        previewFill = pFill
        previewPills = pills
        appDimIconBox = checkbox("Dim the menu bar icon while StayAwake is off", 14, #selector(appDimIconToggled(_:)))
        appearance.addSubview(appDimIconBox!)

        // — Shortcuts —
        let shortcuts = NSView()
        let scLabel = NSTextField(labelWithString: "Activate/deactivate StayAwake:")
        scLabel.frame = NSRect(x: 24, y: 232, width: 300, height: 18)
        shortcuts.addSubview(scLabel)
        let rec = NSButton(title: "Record Shortcut", target: self, action: #selector(recordShortcutClicked))
        rec.frame = NSRect(x: 24, y: 192, width: 200, height: 30)
        rec.bezelStyle = .rounded
        shortcuts.addSubview(rec)
        shortcutButton = rec
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcutClicked))
        clear.frame = NSRect(x: 232, y: 192, width: 70, height: 30)
        clear.bezelStyle = .rounded
        shortcuts.addSubview(clear)
        shortcuts.addSubview(caption("Recommended: ⌃⌥⌘S — already set as the default.", 158))
        shortcuts.addSubview(caption("StayAwake also answers to URLs, so Apple Shortcuts, scripts, Raycast, and Alfred can drive it: stayawake://activate?minutes=30, stayawake://deactivate, stayawake://toggle.", 96, 44))

        // — Advanced —
        let advanced = NSView()
        let durLabel = NSTextField(labelWithString: "Default duration:")
        durLabel.frame = NSRect(x: 24, y: 234, width: 130, height: 18)
        advanced.addSubview(durLabel)
        let popup = NSPopUpButton(frame: NSRect(x: 150, y: 230, width: 190, height: 26), pullsDown: false)
        for (title, _) in durationChoices { popup.addItem(withTitle: title) }
        popup.target = self
        popup.action = #selector(durationPopupChanged)
        advanced.addSubview(popup)
        advDurationPopup = popup
        advDisplaySleepBox = checkbox("Allow display to sleep while awake", 190, #selector(advDisplaySleepToggled(_:)))
        advPauseLockBox = checkbox("Pause while the screen is locked", 160, #selector(advPauseLockToggled(_:)))
        advOffBatteryBox = checkbox("Deactivate when switching to battery", 130, #selector(advOffBatteryToggled(_:)))
        advLowBatteryBox = checkbox("Stop at 20% battery", 100, #selector(advLowBatteryToggled(_:)))
        advChimeBox = checkbox("Play a sound when a session ends", 70, #selector(advChimeToggled(_:)))
        advanced.addSubview(advDisplaySleepBox!)
        advanced.addSubview(advPauseLockBox!)
        advanced.addSubview(advOffBatteryBox!)
        advanced.addSubview(advLowBatteryBox!)
        advanced.addSubview(advChimeBox!)
        advanced.addSubview(caption("The default duration is what the hotkey, left-click activation, and Activate at launch use.", 30, 26))

        // — Updates —
        let updates = NSView()
        let updVersion = NSTextField(labelWithString: "StayAwake \(currentVersion)")
        updVersion.frame = NSRect(x: 24, y: 248, width: 404, height: 20)
        updVersion.font = .systemFont(ofSize: 13, weight: .bold)
        updates.addSubview(updVersion)
        let updStatus = NSTextField(wrappingLabelWithString: updateStatusText)
        updStatus.frame = NSRect(x: 24, y: 198, width: 404, height: 42)
        updStatus.font = .systemFont(ofSize: 12)
        updates.addSubview(updStatus)
        updatesStatusLabel = updStatus
        let updButton = NSButton(title: "Check for Updates…", target: self, action: #selector(updateCheckClicked))
        updButton.frame = NSRect(x: 24, y: 158, width: 180, height: 30)
        updButton.bezelStyle = .rounded
        updates.addSubview(updButton)
        updates.addSubview(caption("StayAwake checks a small public version feed — the only network request it ever makes, and it sends nothing about you or your Mac. Downloads are verified against the feed's SHA-256 checksum before they install.", 92, 56))

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "StayAwake Settings"
        w.isReleasedWhenClosed = false
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        tabView.autoresizingMask = [.width, .height]
        tabView.addTabViewItem(tab("General", "gearshape", general))
        tabView.addTabViewItem(tab("Appearance", "paintpalette", appearance))
        tabView.addTabViewItem(tab("Shortcuts", "command", shortcuts))
        tabView.addTabViewItem(tab("Advanced", "slider.horizontal.3", advanced))
        tabView.addTabViewItem(tab("Updates", "arrow.down.circle", updates))
        w.contentView = tabView
        settingsWindow = w
    }

    private func stylePreview() {
        let theme = currentTheme
        previewBG?.layer?.backgroundColor = theme.background.cgColor
        previewTitle?.textColor = theme.primaryText
        previewTime?.textColor = theme.primaryText
        previewStatus?.textColor = theme.secondaryText
        previewTrack?.layer?.backgroundColor = theme.track.cgColor
        previewFill?.layer?.backgroundColor = theme.accent.cgColor
        for (pill, lab) in previewPills {
            pill.layer?.backgroundColor = theme.buttonBackground.cgColor
            lab.textColor = theme.buttonText
        }
    }

    /// Sync every control in the settings window with the live values.
    /// Called when the window opens and after any change (menu toggles
    /// included, via buildMenu), so the two never disagree.
    private func refreshSettingsControls() {
        guard settingsWindow != nil else { return }
        if #available(macOS 13.0, *) {
            genLaunchLoginBox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            genLaunchLoginBox?.isEnabled = true
        } else {
            genLaunchLoginBox?.isEnabled = false
        }
        genActivateAtLaunchBox?.state = activateAtLaunch ? .on : .off
        genLeftClickBox?.state = activateOnLeftClick ? .on : .off
        genShowPanelBox?.state = showPanelOnStart ? .on : .off
        if let popup = advDurationPopup {
            let idx = durationChoices.firstIndex(where: { $0.1 == defaultMinutes }) ?? 0
            popup.selectItem(at: idx)
        }
        advDisplaySleepBox?.state = allowDisplaySleep ? .on : .off
        advPauseLockBox?.state = pauseOnLock ? .on : .off
        advOffBatteryBox?.state = offOnBattery ? .on : .off
        advLowBatteryBox?.state = lowBatteryGuard ? .on : .off
        advChimeBox?.state = chimeOnEnd ? .on : .off
        updatesStatusLabel?.stringValue = updateStatusText
        appDimIconBox?.state = dimIconWhenOff ? .on : .off
        for (i, b) in swatchButtons.enumerated() {
            b.state = themes[i].name == themeName ? .on : .off
        }
        stylePreview()
        if recordingMonitor == nil { refreshShortcutButtonTitle() }
    }

    private func refreshShortcutButtonTitle() {
        shortcutButton?.title = shortcutDisplayString() ?? "Record Shortcut"
    }

    // MARK: Settings control handlers
    @objc private func genActivateAtLaunchToggled(_ sender: NSButton) {
        activateAtLaunch = sender.state == .on
    }
    @objc private func genLeftClickToggled(_ sender: NSButton) {
        activateOnLeftClick = sender.state == .on
    }
    @objc private func genShowPanelToggled(_ sender: NSButton) {
        showPanelOnStart = sender.state == .on
    }
    @objc private func appDimIconToggled(_ sender: NSButton) {
        dimIconWhenOff = sender.state == .on
        updateUI()
    }
    @objc private func advDisplaySleepToggled(_ sender: NSButton) {
        allowDisplaySleep = sender.state == .on
        if isActive {
            releaseAssertions()
            if !createAssertions() { sleepAssertionFailed() }
        }
        buildMenu()
    }
    @objc private func advPauseLockToggled(_ sender: NSButton) {
        pauseOnLock = sender.state == .on
    }
    @objc private func advOffBatteryToggled(_ sender: NSButton) {
        offOnBattery = sender.state == .on
        buildMenu()
    }
    @objc private func advLowBatteryToggled(_ sender: NSButton) {
        lowBatteryGuard = sender.state == .on
        buildMenu()
    }
    @objc private func advChimeToggled(_ sender: NSButton) {
        chimeOnEnd = sender.state == .on
    }
    @objc private func durationPopupChanged() {
        guard let popup = advDurationPopup else { return }
        let idx = popup.indexOfSelectedItem
        if durationChoices.indices.contains(idx) {
            defaultMinutes = durationChoices[idx].1
        }
    }
    @objc private func swatchClicked(_ sender: NSButton) {
        guard themes.indices.contains(sender.tag) else { return }
        themeName = themes[sender.tag].name
        applyTheme()
        refreshSettingsControls()
        buildMenu()
    }

    // MARK: Shortcut recording
    @objc private func recordShortcutClicked() {
        if recordingMonitor != nil {
            stopRecording()
            refreshShortcutButtonTitle()
            return
        }
        shortcutButton?.title = "Type shortcut… (Esc to cancel)"
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc cancels
                self.stopRecording()
                self.refreshShortcutButtonTitle()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags.isEmpty { return nil } // a modifier is required; keep listening
            self.hotkeyKeyCode = Int(event.keyCode)
            self.hotkeyModifiers = Self.carbonModifiers(from: flags)
            self.registerHotkey()
            self.stopRecording()
            self.refreshShortcutButtonTitle()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
    }

    @objc private func clearShortcutClicked() {
        stopRecording()
        hotkeyKeyCode = -1
        registerHotkey()
        refreshShortcutButtonTitle()
    }
}

// MARK: - Main
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar app, no Dock icon
app.run()
