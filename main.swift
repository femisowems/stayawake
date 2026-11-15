// StayAwake for Mac — native version of the Library app.
// Single-file AppKit app: menu bar item + floating always-on-top mini timer.
//
// Features (mirroring the Library version and Lungo):
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
//   - End-of-session chime
//
// Build with ./build.sh (swiftc, Xcode Command Line Tools). No dependencies.

import Cocoa
import IOKit.pwr_mgt

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: State
    private var statusItem: NSStatusItem!
    private var assertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var startedAt: Date?
    private var deadline: Date?
    private var totalSeconds: Int = 0
    private var timer: Timer?
    private var tickCount: Int = 0

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

    var isActive: Bool { assertionID != 0 }
    var isIndefinite: Bool { isActive && deadline == nil }

    // MARK: Mini timer panel UI
    private var panel: NSPanel?
    private var timeLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var endLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateUI()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
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
    private func createAssertions() {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAwake is keeping this Mac awake" as CFString,
            &assertionID)
        if !allowDisplaySleep {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "StayAwake is keeping the display awake" as CFString,
                &displayAssertionID)
        }
    }

    private func releaseAssertions() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        if displayAssertionID != 0 { IOPMAssertionRelease(displayAssertionID); displayAssertionID = 0 }
    }

    // MARK: Session control
    func activate(minutes: Int) {
        releaseAssertions()
        createAssertions()
        startedAt = Date()
        if minutes > 0 {
            totalSeconds = minutes * 60
            deadline = Date().addingTimeInterval(TimeInterval(totalSeconds))
        } else {
            totalSeconds = 0
            deadline = nil
        }
        showPanel()
        buildMenu()
        updateUI()
    }

    func deactivate(chime: Bool = false) {
        releaseAssertions()
        startedAt = nil
        deadline = nil
        totalSeconds = 0
        panel?.orderOut(nil)
        if chime { NSSound(named: NSSound.Name("Glass"))?.play() }
        buildMenu()
        updateUI()
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
            deactivate(chime: true)
            return
        }
        // Battery checks roughly every 10 seconds (20 ticks at 0.5s).
        if tickCount % 20 == 0 {
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
        updateUI()
    }

    /// Returns (percent charged if readable, true if currently drawing from battery).
    private func batteryInfo() -> (Int?, Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (nil, false) }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let onBattery = text.contains("Battery Power")
        var percent: Int? = nil
        if let range = text.range(of: "%") {
            let before = text[text.startIndex..<range.lowerBound]
            let digits = before.reversed().prefix { $0.isNumber }
            if !digits.isEmpty {
                percent = Int(String(digits.reversed()))
            }
        }
        return (percent, onBattery)
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

        let effect = NSVisualEffectView(frame: rect)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        p.contentView = effect

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

        let time = label(NSRect(x: 16, y: 108, width: 288, height: 42),
                         size: 30, weight: .bold, color: .white)
        time.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        time.stringValue = "0:00"
        timeLabel = time

        statusLabel = label(NSRect(x: 16, y: 90, width: 288, height: 16),
                            size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.65))
        endLabel = label(NSRect(x: 16, y: 48, width: 288, height: 16),
                         size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.65))

        let bar = NSProgressIndicator(frame: NSRect(x: 16, y: 70, width: 288, height: 10))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = false
        effect.addSubview(bar)
        progressBar = bar

        func button(_ title: String, x: CGFloat, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 12, width: 64, height: 26)
            b.bezelStyle = .rounded
            effect.addSubview(b)
            return b
        }
        _ = button("Hide", x: 16, action: #selector(hidePanel))
        _ = button("+15 min", x: 168, action: #selector(add15Clicked))
        _ = button("Stop", x: 240, action: #selector(stopClicked))

        // Default spot: top-right of the main screen, below the menu bar.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.maxX - 336, y: visible.maxY - 204))
        }
        panel = p
    }

    private func showPanel() {
        makePanelIfNeeded()
        panel?.orderFrontRegardless()
    }

    @objc private func hidePanel() { panel?.orderOut(nil) }
    @objc private func add15Clicked() { add15() }
    @objc private func stopClicked() { deactivate() }

    // MARK: UI updates
    private func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

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
        if !isActive {
            if let image = menuBarImage(active: false) {
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = "💤"
            }
            button.toolTip = "StayAwake is off"
            return
        }
        button.image = menuBarImage(active: true)
        button.imagePosition = .imageLeading
        if let deadline {
            let left = Int(deadline.timeIntervalSinceNow)
            button.title = button.image == nil ? "☕ " + format(left) : format(left)
            timeLabel?.stringValue = format(left)
            statusLabel?.stringValue = "ON — holding screen awake"
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            endLabel?.stringValue = "Ends " + formatter.string(from: deadline)
            if totalSeconds > 0 {
                let elapsed = totalSeconds - left
                progressBar?.doubleValue = Double(elapsed) / Double(totalSeconds) * 100
            }
        } else {
            button.title = button.image == nil ? "☕ ∞" : "∞"
            let elapsed = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            timeLabel?.stringValue = format(elapsed)
            statusLabel?.stringValue = "ON — runs until you stop it"
            endLabel?.stringValue = "No end time"
            progressBar?.doubleValue = 100
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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit StayAwake", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
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
        if alert.runModal() == .alertFirstButtonReturn, let mins = Int(field.stringValue), mins > 0 {
            activate(minutes: mins)
        }
    }

    @objc private func showPanelClicked() { showPanel() }

    @objc private func toggleDisplaySleep() {
        allowDisplaySleep.toggle()
        if isActive {
            // Re-create assertions under the new setting, keeping the session.
            let wasIndefinite = isIndefinite
            releaseAssertions()
            createAssertions()
            _ = wasIndefinite
        }
        buildMenu()
    }

    @objc private func toggleOffOnBattery() { offOnBattery.toggle(); buildMenu() }
    @objc private func toggleLowBatteryGuard() { lowBatteryGuard.toggle(); buildMenu() }
    @objc private func quitClicked() { deactivate(); NSApp.terminate(nil) }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar app, no Dock icon
app.run()
