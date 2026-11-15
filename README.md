# StayAwake for Mac

[![Build](https://github.com/femisowems/stayawake/actions/workflows/build.yml/badge.svg)](https://github.com/femisowems/stayawake/actions/workflows/build.yml)

**Keep your Mac awake for exactly as long as you need — no more, no less.**

StayAwake is a tiny, free, open-source macOS menu bar app that prevents your
Mac (and optionally its display) from sleeping for a preset time, a custom
duration, or indefinitely. It was built for a simple, real need: keeping a
MacBook awake during long uploads, downloads, renders, and exports while you
step away — without digging through System Settings or leaving a
`caffeinate` command running in a terminal you might close by accident.

It does the same core job as the commercial app Lungo, using the same
underlying macOS mechanism (IOKit power assertions — the system API behind
`caffeinate`), in a single Swift file with **no dependencies, no account, no
tracking, and nothing sent anywhere**.

---

## Features

- **Menu bar app, no Dock icon** — a native coffee-cup glyph (SF Symbol,
  adapts to light/dark menu bars) with a live countdown while a session
  runs, a moon glyph when off.
- **Preset durations** — 15 min, 30 min, 1 hour, 2 hours, 4 hours, 8 hours.
- **Custom duration** — enter any number of minutes.
- **Indefinite mode** — stay awake until you stop it.
- **Floating mini timer** — a compact 320×188 panel that is *truly* always
  on top: it floats above other windows, follows you across Spaces, shows
  over full-screen apps, and can be dragged anywhere. It shows the live
  countdown (or elapsed time in indefinite mode), a progress bar, the end
  time, and **+15 min**, **Stop**, and **Hide** buttons. Starting a session
  pops it to the top-right of your screen; *Show mini timer* in the menu
  brings it back.
- **Real sleep prevention** — IOKit power management assertions prevent
  system sleep for the whole session; display sleep is also prevented
  unless you turn it off (below).
- **Allow display to sleep** (optional) — keep the *system* working while
  letting the screen go dark, for overnight jobs.
- **Battery safeguards**
  - *Stop on low battery* (on by default): the session ends automatically
    if the battery reaches 20% while discharging, so an unattended laptop
    never drains itself flat.
  - *Deactivate when switching to battery* (optional): the session ends
    the moment you unplug.
- **End-of-session chime** — a soft Glass sound when a timed session
  expires, so you know it finished.
- **Settings that stick** — the three toggles below are saved and
  restored on relaunch, not reset every time you quit.
- **Scriptable** — a `stayawake://` URL scheme (see *Automation* below)
  lets Shortcuts, shell scripts, Raycast, Alfred and friends start and
  stop sessions.
- **Launch at login** — a menu toggle (macOS 13+) so StayAwake is
  already in your menu bar when you log in. Every push to this repo is
  also compiled by GitHub Actions on a macOS runner, with the built app
  attached to the run as a downloadable artifact.
- **Four panel themes** — the mini timer comes in *Midnight Teal*
  (default, matches the icon), *Graphite*, *Daylight*, and *Amber Dusk*,
  switchable from the menu's **Theme** submenu and remembered between
  launches. Themes are solid colour sets, so the countdown stays
  readable against any desktop — the old translucent HUD could wash its
  white text out to near-invisible on light backgrounds.
- **A Settings window of its own** — **Settings…** (⌘,) opens a
  four-tab window: *General* (launch at login, activate at launch,
  activate on left-click, mini timer on start), *Appearance* (the four
  themes as swatches with a **live preview** of the mini timer, plus a
  dimmed menu bar icon while off), *Shortcuts* (a recordable global
  hotkey, ⌃⌥⌘S by default), and *Advanced* (default duration, display
  sleep, pause while the screen is locked, battery options, end-of-
  session sound). Every setting ships with a sensible default already
  selected and persists between launches; on an existing install the
  window simply shows your current values.
- **Private by design** — no data collected, no settings synced, no
  network calls. The app has nothing to phone home with.

## Requirements

- macOS 11 (Big Sur) or later
- To build from source: the free **Xcode Command Line Tools** (for
  `swiftc`). You do **not** need the full Xcode app, an Apple Developer
  account, or the App Store.

## Quick start

```sh
git clone https://github.com/femisowems/stayawake.git
cd stayawake
chmod +x build.sh
./build.sh
```

That compiles the app and produces **`StayAwake.app`** in the same folder,
with its icon bundled and an ad-hoc code signature applied.

If the build says `swiftc` is missing, install the Command Line Tools
first, wait for Apple's installer to finish, then run `./build.sh` again:

```sh
xcode-select --install
```

## Installing

1. Drag **`StayAwake.app`** into your **Applications** folder.
2. Double-click it. A ☕ (or 💤) appears in your menu bar — there is no
   window and no Dock icon; the app lives entirely in the menu bar.
3. **First launch:** the build is ad-hoc signed rather than notarized, so
   if macOS refuses to open it or shows a warning, **right-click the app
   → Open → Open** once. After that it launches normally.

Tip: on macOS 13+, use the **Launch at login** toggle in the app's menu
to start StayAwake automatically. On older systems, add it under
**System Settings → General → Login Items**.

## First launch — the "Apple could not verify" dialog

If you downloaded a prebuilt `StayAwake.app` (for example the artifact
from a CI run) instead of building it yourself, the first launch will
likely show:

> **"StayAwake" Not Opened** — Apple could not verify "StayAwake" is
> free of malware that may harm your Mac or compromise your privacy.

This is expected, and it does not mean anything is wrong with the app.
StayAwake is signed with an ad-hoc signature, not a paid Apple Developer
ID, and it is not notarized — so Gatekeeper blocks any *downloaded* copy
until you approve it once. The source is right here in this repo; the
build takes one command, and CI builds it from this exact code.

**Do not click "Move to Trash."** Click **Done**, then approve it once:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section. You will see a line saying
   "StayAwake" was blocked to protect your Mac.
3. Click **Open Anyway**, authenticate (Touch ID or password), then
   click **Open** in the confirmation dialog.

StayAwake launches, and macOS remembers the exception — every later
launch, including updates you replace in place in Applications, opens
normally.

**Terminal alternative** (same result, one command — it removes the
"downloaded from the internet" quarantine flag that triggers the block):

```sh
xattr -dr com.apple.quarantine /Applications/StayAwake.app
```

**Skip the dialog entirely:** build from source instead (see *Quick
start*). An app compiled on your own Mac is never quarantined, so it
opens without any of this.

## How to use it

Click the menu bar icon to open the menu:

| Action | What it does |
| --- | --- |
| **15m / 30m / 1h / 2h / 4h / 8h** | Start a timed session for that long. |
| **Custom minutes…** | Start a session for any duration you enter. |
| **Indefinitely** | Stay awake until you choose Stop. |
| **Stop** | End the current session immediately. |
| **Show mini timer** | Bring the floating mini timer panel back if you hid it. |
| **Allow display to sleep while awake** | Toggle: system stays awake, screen may sleep. |
| **Stop on low battery (≤20%)** | Toggle: auto-stop at 20% battery while unplugged (default on). |
| **Deactivate when switching to battery** | Toggle: end the session when unplugged (default off). |
| **Theme →** | Pick the mini timer's colour theme: Midnight Teal, Graphite, Daylight, or Amber Dusk. |
| **Launch at login** | Toggle automatic start at login (macOS 13+). The menu also shows the current version at the top. |
| **Settings…** (⌘,) | Open the Settings window: General, Appearance (theme swatches with a live mini-timer preview), Shortcuts (recordable global hotkey, ⌃⌥⌘S by default), and Advanced (default duration, pause while locked, battery options, end-of-session sound). |
| **Quit StayAwake** | Quit the app (also ends any session). |

While a session runs, the menu bar shows ☕ plus the time remaining, and
the mini timer counts down with a progress bar and the exact end time.
Use **+15 min** on the mini timer to extend a session without reopening
the menu, or **Stop** to end it on the spot.

### Good to know

- Closing the mini timer panel (**Hide**) does **not** end the session —
  the countdown in the menu bar keeps running.
- Quitting the app, shutting down, or closing the lid ends a session.
- Settings (the three toggles) apply immediately and persist across
  relaunches — set them once.

## Automation — the `stayawake://` URL scheme

StayAwake registers a URL scheme, so anything that can open a URL can
drive it:

| URL | Effect |
| --- | --- |
| `stayawake://activate?minutes=30` | Start a 30-minute session (any number works) |
| `stayawake://activate` | Start an indefinite session |
| `stayawake://deactivate` | End the current session |
| `stayawake://toggle` | Start (indefinite) if off, stop if on |
| `stayawake://toggle?minutes=45` | Toggle with a 45-minute session |

From Terminal:

```sh
open "stayawake://activate?minutes=60"
```

In **Shortcuts**, use the *Open URLs* action with one of the URLs above —
that is the easiest way to bind a session to a keyboard shortcut, a Focus
mode, or a time of day. (Native App Intents would need a full Xcode
project; the URL scheme covers the same ground for this app.)

## Limits (these are macOS limits, not app bugs)

- **Lid closed:** with the lid shut, a MacBook sleeps no matter what —
  unless it is on a charger with an external display attached. Keep the
  lid open for unattended jobs.
- **Scheduled sleep/shutdown:** a `pmset` sleep schedule or automatic
  logout set in System Settings overrides StayAwake.
- **No fake activity:** StayAwake keeps the machine and screen awake; it
  does not simulate mouse movement or keystrokes, so apps like Slack or
  Teams may still show you as away. That is deliberate.

## Troubleshooting

**`swiftc not found` when building**
Run `xcode-select --install`, let it finish, then `./build.sh` again.

**macOS says the app can't be opened / "Apple could not verify…"**
The app is ad-hoc signed, not notarized by Apple. On current macOS the
dialog has no Open button — see *First launch* above for the
**Open Anyway** steps (or the one-line Terminal fix).

**The menu bar icon doesn't appear**
Make sure you launched the built `StayAwake.app` (not the source files).
Menu bar space can also be tight on notched MacBooks — quit another menu
bar app and relaunch StayAwake.

**The Mac still slept during a session**
Check the lid (must be open on a laptop), any `pmset` schedule
(`pmset -g sched` in Terminal shows them), and whether the battery
safeguard ended the session at 20%.

**I want it to stop doing X / start doing Y**
Open an issue — or edit `main.swift`; it is one file on purpose.

## How it works

StayAwake is a single-file AppKit app (`main.swift`, ~400 lines). It holds
an IOKit power assertion (`IOPMAssertionCreateWithName`) of type
`PreventUserIdleSystemSleep` for the session, plus
`PreventUserIdleDisplaySleep` unless display sleep is allowed — exactly
what the built-in `caffeinate -di` command does, wrapped in a menu bar UI
with a countdown, a floating `NSPanel` mini timer (`.floating` level,
`canJoinAllSpaces` + `fullScreenAuxiliary`), battery monitoring, and an
expiry timer. The toggles persist in `UserDefaults`, and the
`stayawake://` URL scheme arrives as standard open-URL Apple Events.
`build.sh` compiles it with `swiftc`, writes the
`Info.plist` (bundle ID `io.starterdev.stayawake`, `LSUIElement` so there
is no Dock icon, minimum macOS 11, the `stayawake` URL scheme), bundles
the icon, and ad-hoc signs the result.

## Project layout

```
.
├── main.swift     # the entire app
├── build.sh       # one-command build: ./build.sh → StayAwake.app
├── AppIcon.icns   # bundled app icon (all macOS sizes)
├── AppIcon-1024.png
├── .github/workflows/build.yml   # CI: compiles the app on every push
├── LICENSE        # MIT
└── README.md
```

## Why source + a build script, not a downloadable binary?

The app was developed in a Linux workspace with no macOS toolchain, so
the binary has to be compiled on a Mac — `build.sh` does the whole job
in one command. The Swift source has been carefully reviewed; if
`swiftc` prints an error on your machine, please open an issue with the
exact output.

## Privacy

StayAwake collects nothing, stores nothing beyond its own toggle states,
and makes no network connections. There is no analytics, no account, and
no update checker phoning home.

---

Built by [Femi Sowemimo](https://github.com/femisowems) (StarterDev) as a
free alternative to Lungo for a single job: a Mac that stays awake while
the work finishes.
