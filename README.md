# IPAD_BLUETOOTH_MIRACLE — iPad → BLE HID → Windows controller

I am building this because I want my iPad to become a programmable Windows input/control surface:
a standard Bluetooth HID keyboard + mouse/trackpad (BLE HID over GATT) as far as any PC is
concerned, so Windows needs no companion software for basic control.

**Immediate focus:**
- BLE HID keyboard + mouse (HOGP) to Windows
- Trackpad and game (high-rate raw touch) input
- Direct Input — pass-through of a physical Windows keyboard/mouse connected to the iPad
- Windows controls (Ctrl / Win / Alt / Shift, extended keys) and a control DECK (Windows shortcuts,
  navigation, F1–F12)

## Origin
The codebase started from imported code from the open-source project
[jqssun/darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote) — imported at upstream commit
`ad7a76ce6132254fbd6085af87cea8d10aa8a82d` (verified to exist on GitHub; the import is recorded in
this repo's baseline commit `95b69a1`). This repository was created independently — it is **not** a
GitHub fork. Upstream attribution and licensing (**AGPL-3.0-only**, see `LICENSE`) are preserved.

## Build path (no paid Apple Developer account)
Windows → git push → GitHub Actions (macOS runner: xcodegen + xcodebuild, `CODE_SIGNING_ALLOWED=NO`)
→ unsigned `btr-remote-unsigned-ipa` artifact → install on the iPad via SideStore/Sideloadly
(re-signed locally with a free Apple ID).

## Currently implemented
- BLE HID-over-GATT (HOGP) peripheral: keyboard + mouse + consumer reports to Windows; auto-
  advertising on launch; visible Bluetooth connection state
- Mouse: relative move, tap = left click, two-finger tap = right click, two-finger move = scroll,
  drag (1-finger pan)
- Keyboard: typing via the input field; keycaps Ctrl / Win / Alt / Shift (full press+release since
  the Win-key fix `0bccedc`); extended keys + temporary F1–F12 grid
- Direct Input: a physical Windows keyboard/mouse connected to the iPad passes through to Windows;
  release chord Ctrl+Alt+Backspace (configurable)
- GAME mode: coalesced raw touch sampling (`UIEvent.coalescedTouches(for:)`, no predicted
  touches); performance metrics overlay (hidden by default)
- DECK: Windows shortcuts + navigation + F-keys (page 2)
- Verified on hardware (basic path only): pairing, mouse move/tap/scroll, typing

## Current limitations (brief)
- The Win-key fix (`0bccedc`) is built and CI-green, but the full physical acceptance (Win tap →
  Start; Win+L → login → Alt+Tab → typing; GAME metrics) is **not yet re-verified**
- After that fix, multi-key combinations via on-screen modifier keycaps (e.g. Ctrl+letter) are no
  longer sendable — dedicated combined keycaps / restored sticky behavior are the next planned
  fix (see `SPEC.md` §10)
- TOUCH mode (absolute digitizer), gyro aim and native dictation: not implemented
- Compilation of any newer Swift edits is unverified without a new CI run (no Xcode on the dev
  machine); some imported upstream features (iPhone remote, macOS Bluetooth Classic backend, TV
  remote) are out of scope for this product

## Specification
Everything that is IMPLEMENTED / MEASURED / PLANNED / PARKED, the UX canon and the acceptance
criteria live in the single canonical specification: [SPEC.md](SPEC.md).
