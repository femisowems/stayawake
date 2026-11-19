// StayAwake logic tests (v2.5.0).
//
// Built only by run-tests.sh, which CI runs before the app
// build: bash run-tests.sh (it strips the app entry from
// main.swift into a copy, then compiles it with this file).
// The checks cover the pure logic — duration formatting, the
// custom-minutes parser, battery percentage maths, the update
// feed's version compare and the Carbon modifier mapping —
// the parts a compile-only CI could not see break. Any
// failure exits 1 and fails the CI run.
import Foundation
import AppKit

var totalChecks = 0
var failedChecks = 0

func check(_ name: String, _ condition: Bool) {
    totalChecks += 1
    if condition {
        print("PASS: \(name)")
    } else {
        failedChecks += 1
        print("FAIL: \(name)")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual != expected {
        print("  expected: \(expected)")
        print("  actual:   \(actual)")
    }
    check(name, actual == expected)
}

@main
struct StayAwakeTests {
    static func main() {
        // Duration formatting — the mini timer and the menu bar
        // countdown both render through formatDuration.
        checkEqual("format: zero", formatDuration(0), "0:00")
        checkEqual("format: seconds pad", formatDuration(5), "0:05")
        checkEqual("format: under a minute", formatDuration(59), "0:59")
        checkEqual("format: one minute", formatDuration(60), "1:00")
        checkEqual("format: minutes and seconds", formatDuration(599), "9:59")
        checkEqual("format: under an hour", formatDuration(3599), "59:59")
        checkEqual("format: one hour switches shape", formatDuration(3600), "1:00:00")
        checkEqual("format: hours minutes seconds", formatDuration(3661), "1:01:01")
        checkEqual("format: ten hours", formatDuration(36000), "10:00:00")
        checkEqual("format: negative clamps to zero", formatDuration(-30), "0:00")

        // Custom-minutes parsing — only a positive whole number
        // starts a session.
        checkEqual("minutes: plain", parseCustomMinutes("45"), 45)
        checkEqual("minutes: whitespace trimmed", parseCustomMinutes(" 30 "), 30)
        checkEqual("minutes: one", parseCustomMinutes("1"), 1)
        check("minutes: zero rejected", parseCustomMinutes("0") == nil)
        check("minutes: negative rejected", parseCustomMinutes("-5") == nil)
        check("minutes: text rejected", parseCustomMinutes("abc") == nil)
        check("minutes: empty rejected", parseCustomMinutes("") == nil)
        check("minutes: decimal rejected", parseCustomMinutes("12.5") == nil)

        // Battery percentage — the low-battery guard decides on
        // this number, so its edges matter.
        checkEqual("battery: half", batteryPercent(current: 50, max: 100), 50)
        checkEqual("battery: empty", batteryPercent(current: 0, max: 100), 0)
        checkEqual("battery: full", batteryPercent(current: 100, max: 100), 100)
        checkEqual("battery: third rounds down", batteryPercent(current: 1, max: 3), 33)
        checkEqual("battery: two thirds rounds up", batteryPercent(current: 2, max: 3), 67)
        checkEqual("battery: over-full clamps", batteryPercent(current: 150, max: 100), 100)
        check("battery: zero max unusable", batteryPercent(current: 10, max: 0) == nil)
        check("battery: negative current unusable", batteryPercent(current: -1, max: 100) == nil)

        // Update-feed version compare.
        check("version: minor bump is newer", isNewerVersion("2.5.0", than: "2.4"))
        check("version: older is not newer", !isNewerVersion("2.4", than: "2.5.0"))
        check("version: equal is not newer", !isNewerVersion("2.5.0", than: "2.5.0"))
        check("version: missing patch counts as zero", !isNewerVersion("2.5", than: "2.5.0"))
        check("version: two-digit minor compares numerically", isNewerVersion("2.10.0", than: "2.9.9"))
        check("version: major bump is newer", isNewerVersion("3.0", than: "2.99.9"))
        check("version: patch bump is newer", isNewerVersion("2.5.1", than: "2.5.0"))
        check("version: lower patch is not newer", !isNewerVersion("2.5.0", than: "2.5.1"))

        // Carbon modifier mapping — the recorded hotkey and the
        // default (⌃⌥⌘S = 6400) depend on these bit values.
        checkEqual("modifiers: command", AppDelegate.carbonModifiers(from: .command), 256)
        checkEqual("modifiers: shift", AppDelegate.carbonModifiers(from: .shift), 512)
        checkEqual("modifiers: default combo", AppDelegate.carbonModifiers(from: [.control, .option, .command]), 6400)
        checkEqual("modifiers: none", AppDelegate.carbonModifiers(from: []), 0)

        print("—")
        if failedChecks == 0 {
            print("ALL \(totalChecks) CHECKS PASSED")
        } else {
            print("\(failedChecks) of \(totalChecks) CHECKS FAILED")
        }
        exit(failedChecks == 0 ? 0 : 1)
    }
}
