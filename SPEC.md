# SPEC.md — canonical product/technical specification

**Versioned by Git SHA only. No manual Spec-Version.** This file is the single specification of
record for this repository; old docs are subordinate to current Git + this file (git history is
the archive — do not recreate `docs/archive/` or parallel roadmap/architecture/P2/layout specs).

Rule: any future change to expected behavior, architecture, UX contract, acceptance criteria or
active scope must change `SPEC.md` before implementation, in a separate spec commit. Example:
`spec(game): define gyro aim behavior` → then `feat(game): implement gyro aim [spec <sha>]`.
Implementation commits/PRs must reference the SPEC commit SHA they follow. Pure fixes restoring
already-specified behavior do not require a spec commit.

## 1. Product intent
Make an iPad a programmable Windows input/control surface: the iPad presents itself to a Windows
PC as a standard Bluetooth HID keyboard + mouse/trackpad (BLE HID over GATT / HOGP), so Windows
needs no companion software for basic control. Motivation: drive Windows from an iPad — trackpad/
mouse, typing, game (aim) input and Windows controls.

## 2. Origin and licensing
- Codebase started from imported code of the open-source project
  [jqssun/darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote), imported at upstream
  commit `ad7a76ce6132254fbd6085af87cea8d10aa8a82d` (verified to exist on GitHub 2026-09-21 via
  GitHub API). The import is recorded in this repository's git history, baseline commit `95b69a1`
  ("chore: establish upstream baseline (import jqssun/darwin-bt-remote, AGPL-3.0-only preserved)").
- This repository (`Kryptas531/IPAD_BLUETOOTH_MIRACLE`) was created independently; it is **not**
  a GitHub fork.
- Upstream attribution and licensing are preserved: **AGPL-3.0-only**, `LICENSE` file unchanged.

## 3. Target hardware / deployment
- Primary target: **iPad Air 11-inch (M2, 2024) + Windows 10/11 PC** with Bluetooth LE
  (physical device must be BLE-capable; old `docs/PHYSICAL_TEST.md` pre-checks, migrated).
- iPad = BLE HID-over-GATT (HOGP) peripheral (keyboard + mouse + consumer); Windows = ordinary
  Bluetooth HID host. No Windows-side software in current scope.
- No paid Apple Developer Program: build = unsigned IPA via GitHub Actions; install via
  SideStore/Sideloadly (re-sign on device with free Apple ID).
- Imported upstream extras (iPhone remote UI, Bluetooth Classic backend, TV-remote DPad) are
  out of scope for this product.

## 4. Current architecture
Swift/SwiftUI app `BTRemote`; Xcode project generated via xcodegen from `project.yml` (project
not committed; Swift 6.0, strict concurrency complete; iOS deployment target 15.0).

Transport: **BLE HID over GATT only.** `BTRemote/LowEnergy/`: `HIDPeripheral.swift`
(CBPeripheralManager, HID service 0x1812, Report Map, Protocol Mode, Boot Keyboard I/O, report
references, `*EncryptionRequired`, bootstrap report on subscribe; `sendMouse`/`sendKeyboard`/
`sendConsumer`/`sendSystemControl`), `HIDProfile.swift` (UUIDs + 239-byte report map),
`HIDReports.swift` (MouseReport, KeyboardReport 8 bytes, ConsumerReport, Keycode enum),
`HIDCentral.swift`.

Bluetooth Classic backend (`BTRemote/Classic/`, IOBluetooth SDP/L2CAP) exists but is **macOS-only**
and unused in the iPad→Windows path (upstream README: no Windows-over-HIDP support).

UI/entry: `BTRemoteApp.swift` (@main; onAppear `central.start()` + `if autoAdvertise { lowEnergy.start() }`
— iPad auto-advertises the HID service) → `ContentView` (Setup/Remote/Settings; auto-switch to
Remote when connected) → `RemoteTabView` → `KeyboardView` (TextField + keycaps + `KeyTypist`) +
`TrackpadPanel`/`TouchpadView`, `RemoteView` (DECK), `DirectInputController.swift`, `Controls.swift`
(HoldButton/PressGesture), `AppSettings.swift`, `BluetoothNumbers.swift`, `L10n.swift` +
`Localizable.xcstrings` + `InfoPlist.xcstrings` + `PrivacyInfo.xcprivacy`, `Info.plist`,
`entitlements.plist`.

UI→HID routing: `BTRemote/HIDInput.swift` (`tap(key:modifiers:)`, `type(char)`, `click(.left/.
right)`, `move(dx:dy:)`, `scroll(wheel)`, `keyReports(for:modifiers:)`; ASCII→keycode maps
`mapASCII`/`_symbolKeys`).

**Protected boundary (do not modify without a proven, explicitly stated need + focused review):**
`BTRemote/LowEnergy/`, `BTRemote/Classic/`, `BTRemote/HIDInput.swift`, `BTRemote/HIDReports.swift`
— plus `BTRemote/Resources/*.json` (not in git; downloaded during CI by
`ci_scripts/ci_post_clone.sh` from `NordicSemiconductor/bluetooth-numbers-database`, verified by
reading the script) and `BTRemote/Info.plist`/`entitlements.plist` (contents not read in prior
sessions — ci-worker zone).

## 5. IMPLEMENTED behavior
(Code exists in current main as of code HEAD `0bccedc`; Swift compilation was never possible
locally — Windows without Xcode/swift — so build verification = CI only, see §12.)
- **BLE pairing:** iPad auto-advertises HID on launch; Windows pairs it as a standard BT
  keyboard+mouse; connection state visible in app (`SetupView`/`NotConnectedView`).
  IMPLEMENTED + MEASURED (user confirmed basic path finger→BLE→Windows + typing on hardware).
- **Mouse:** relative move (`HIDInput.move`), left click (tap), right click (two-finger tap),
  vertical scroll (two-finger move), drag (1-finger pan). IMPLEMENTED (CI VERIFIED).
- **Keyboard:** typing through the input field (`KeyTypist`/`HIDInput.type(char)` + ASCII→keycode
  map, ~20 ms pacing). IMPLEMENTED (CI VERIFIED). Letters are not keycaps — typing goes through
  the input field or the physical keyboard.
- **Keycaps Ctrl / Win / Alt / Shift** (Windows semantics, not Command/Option): since `0bccedc`
  each tap sends a full press+release (`KeyboardReport(modifiers: mod, keys: [])` + `.zero` via
  the typist) — a single Win key press reaches the host, but sequential/combined key presses
  through the onscreen modifier keycaps are no longer sendable (see §10). CONTRACT DEFINED for
  the next fix (this spec commit): the main onscreen modifier keycaps (Ctrl / Win / Alt / Shift)
  must behave like physical momentary modifier keys —
  A. touch/press DOWN activates the corresponding modifier; release deactivates it; while a
     modifier is held, pressing another onscreen keycap sends the combined HID report; several
     modifier keycaps can be held simultaneously; releasing one modifier must not release the
     other active modifiers; a short tap of a modifier naturally creates down + up, so a short
     Win tap must still open Start on Windows.
  B. No artificial delay may be added to distinguish a modifier tap from a combination.
  C. The existing sticky modifier mechanism (accessory bar / text-entry flow) must not break;
     two state sets (sticky vs physically held) are allowed to separate them — releasing a held
     modifier must not clear a sticky one; effective modifiers = union(sticky, held), used for
     normal key presses.
  D. Explicit combined shortcuts needed for acceptance: WIN+L and ALT+TAB. Reason WIN+L: there
     are no letter keycaps, so hold-Win + L cannot be assembled with ordinary keycaps. A
     dedicated shortcut must generate the full combined key down + release, sending exactly that
     combination, without accidentally mixing in sticky modifiers.
  E. Physical Direct Input is not changed.
  F. The protected BLE/HID implementation boundary is not changed without a proven need —
     `HIDInput.swift` / `HIDReports.swift` / `LowEnergy/*` are expected to stay untouched.
  G. CI is not physical verification; after CI, hardware behavior stays NOT VERIFIED until the
     user's physical iPad + Windows test.
  Implemented in `ac87c61` [spec `d1b68d9`] — build GREEN (CI run `35642707603`, job
  build-unsigned); hardware behavior stays NOT VERIFIED until the user's physical iPad +
  Windows test.
- **Extended keys + keyboard overlay:** Insert/Delete/Home/End/PgUp/PgDn/arrows + temporary
  F1–F12 grid (`BTRemote/KeyboardView.swift`). Dedicated combined keycaps ALT+TAB and WIN+L are
  part of the contract above (they send exactly that combination via `keyReports`); they live in
  the temporary keyboard/extended overlay so the canonical DECK 4×4 stays unchanged;
  implemented in `ac87c61` (CI run `35642707603` GREEN; physical verification pending).
  The original extended keys are IMPLEMENTED (CI VERIFIED).
- **DECK:** Windows control surface — shortcuts + navigation + F-keys; page 1 (COPY/PASTE/CUT/
  UNDO, TASK MGR, EXPLORER/SEARCH, TASK VIEW = Win+Tab, DESK ←/→ = Win+Ctrl+arrows, SCREENSHOT =
  Win+Shift+S, vol/mute/play-pause), page 2 (ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/HOME/END/
  PGUP/UP/PGDN/LEFT/DOWN/RIGHT/F-KEYS → temporary F-grid); swipe or buttons to switch
  (`BTRemote/RemoteView.swift`). Single-report combos work via `keyReports(for:modifiers:)`.
  IMPLEMENTED (CI VERIFIED).
- **Direct Input:** a physical Windows keyboard/mouse attached to the iPad is captured through
  Game Compatible Controllers (iOS branch: `GCKeyboard.coalesced` / `GCMouse.current`,
  `DirectInputController.swift:384,391`) and forwarded to Windows as HID reports; release chord
  `Ctrl + Alt + Backspace` (`ReleaseChord.defaultChord`, `DirectInputController.swift:507`;
  configurable via `AppSettings`); fallback "Release Direct Input" button in the temporary/
  extended zone. IMPLEMENTED (CI VERIFIED; physical-keyboard pass-through not yet user-tested).
- **GAME high-fidelity input:** `touchesBegan`/`touchesMoved(_:with:)`/`touchesEnded` +
  `UIEvent.coalescedTouches(for:)` (`TouchpadView.swift:222`), chronological sample processing,
  delta from previous ACTUAL sample, predicted touches NOT used for HID mouse movement.
  TRACKPAD stays gesture-based (UIPanGestureRecognizer). IMPLEMENTED (CI VERIFIED).
- **BLE mouse backpressure:** `pendingMouseDX/DY/Wheel` accumulation (`HIDPeripheral.swift:52,118`),
  clamp/split on send (`mouseChunk`), `drainPendingMouse()` after `peripheralManagerIsReady`
  (:382,:582); button state preserved; keyboard/consumer semantics untouched; counters feed
  PerformanceMetrics. IMPLEMENTED (CI VERIFIED).
- **Low connection latency:** `peripheral.setDesiredConnectionLatency(.low, for: central)`
  (`HIDPeripheral.swift:542`) — a request, not a guarantee. IMPLEMENTED.
- **Performance metrics overlay:** `BTRemote/PerformanceMetrics.swift` rolling one-second counters
  (delivered touch Hz, raw/coalesced samples Hz, generated vs accepted BLE mouse reports,
  backpressure count, pending/coalesced, lost delta, avg/max interval + jitter); hidden by default,
  shown in developer mode (`TrackpadPanel.swift`). IMPLEMENTED.
- **Modes UI:** compact switcher GAME | TRACKPAD | TOUCH | DECK + compact status ("BT ● KB ●").
  TOUCH = **EXPERIMENTAL / in development** (absolute digitizer not implemented). IMPLEMENTED.

## 6. MEASURED facts
(From the one good physical run, iPad Air 11" M2 2024 + Windows, 2026-09-20 — do not extend these.)
- iPad ordinary touch events ≈40–60 Hz; raw/coalesced samples up to ≈120 Hz. Touch-event rate is
  the iPad panel's hardware scan limit for one finger — the app cannot raise it.
- Good run: ≈120 raw samples, ≈128 BLE accepted, **lost delta = 0**; raw sample interval ≈8.3 ms.
- Windows Raw Input for BTRemote: **p50 ≈14.8–14.9 ms** — matches the negotiated BLE connection
  interval **15.0 ms**, latency 0, timeout 2000 ms, PHY LE 2M.
- Control experiment (ROG CHAKRAM X over Bluetooth): baseline interval **7.5 ms** → Windows and
  the current BT controller can do 7.5 ms. Windows `ThroughputOptimized` = 15 ms and using it as
  an acceleration path is not needed.
- Basic path confirmed on hardware: pairing + mouse move/tap-click/scroll + keyboard typing.
  The Win-key fix build (from `0bccedc`) was built + CI-green and the IPA downloaded
  (`.qwen/tmp/ipa-p4/BTRemote.ipa`); **Win tap → Start and full acceptance are NOT yet re-verified
  by the user.**
- Do NOT claim: "120 Hz achieved", "latency fixed", "smoother", "game ready" — only the single-run
  values above are confirmed.

## 7. UX canon
(Migrated from `docs/CANON LAYOUT.md` — the former `docs/LAYOT PATCH.md` is SUPERSEDED. Re-derive
details from git history if needed; do not recreate these files.)
- Primary device: iPad Air 11" M2 2024, LANDSCAPE. Idea: maximum input surface, minimum permanent
  controls.
- Very compact top bar `[GAME | TRACKPAD | TOUCH | DECK]` + tiny indicators (`●BT ⌨`); top bar can
  auto-hide in GAME. Settings = modal/sheet, not a big tab.
- No large permanent CONNECTED / DIRECT INPUT / debug / setup-status panels and no long status
  texts; connection/Direct Input = tiny indicators only.
- Trackpad ≈85–90 % of the useful area; no permanent wide right sidebar / scroll column / L-M-R
  rows. Extended keys open temporary overlays, never shrink the trackpad permanently.
- GAME ≈ fullscreen input surface; controls (Touch/Gyro/Hybrid, sensitivity, gyro sensitivity,
  recenter, debug toggle) only as temporary overlay; optional LMB/RMB zones semi-transparent/
  configurable/removable; do not draw a WASD keyboard (external physical keyboard assumed).
- TOUCH ≈100 % surface, controls hidden, edge gestures only (EXPERIMENTAL).
- DECK = Windows control grid 4×4 (page 1 shortcuts, page 2 navigation, F-KEYS → temporary
  F1–F12 grid) — a Windows control surface, not the old media/TV remote.
- Direct Input: compact status icon; capture/release controls via long-press on keyboard
  indicator or in settings; a physical Windows keyboard must keep working as is.
- Dictation: small 🎙 push-to-dictate button, temporary transcript not covering the central
  trackpad (not implemented — placeholder).
- All touch buttons: immediate pressed visual state (+ short click sound if enabled; toggle
  ON/OFF visually clear); never add latency to the input pipeline for animations.
- Working rule from past sessions: first INSPECT the current implementation, minimal layout
  refactor over existing working views, preserve all implemented features, working input paths,
  Direct Input, current CI and BLE behavior.

## 8. Active milestone
Per the reconciled roadmap (2026-09-20/21):
1. UX polish per the UX canon (§7) → 2. TRACKPAD usability → 3. GAME usability → 4. Direct Input /
Windows keyboard semantics → 5. DECK → 6. Gyro aim → 7. Native dictation RU/EN → 8. Feedback →
9. experimental TOUCH / absolute digitizer.

Implemented: **modifier hold + combined keycaps after `0bccedc`** — contract defined in §5
(A–G, spec `d1b68d9`); implemented in `ac87c61`, CI GREEN (run `35642707603`).
Remaining: the user's physical verification per §9.

## 9. Acceptance criteria
(Procedure migrated from `docs/PHYSICAL_TEST.md`. Only the user, on the physical iPad + Windows,
can pass it.)
- Pre-check: iPad iOS 15+ (upstream claim); Windows 10/11 PC with BLE-capable Bluetooth adapter;
  devices near, Bluetooth on.
- 1. Build: get unsigned `.ipa` from the GitHub Actions artifact (after push; §12) and install it
  on the iPad via SideStore.
- 2. Launch: app opens at Setup; "Bluetooth powered on" / "advertising: yes"; auto-start.
- 3. Pairing: Windows Settings → Bluetooth & devices → add the advertised device; app shows
  connected state.
- 4. TRACKPAD gestures: 1-finger move, tap → LMB, two-finger move → scroll, two-finger tap → RMB,
  drag; GAME raw movement path tested separately (high-rate input must not drop deltas).
- 5. Performance metrics: developer mode, GAME, continuous movement ≥10 s; record touch Hz, raw
  samples Hz, mouse generated Hz, BLE accepted Hz, backpressure, pending, coalesced, lost delta,
  avg/max interval. CI cannot infer these.
- 6. Keyboard: typing via input field reaches Windows; ESC/ENTER keycaps work.
- 7. Shortcuts: Win tap → Start opens. Momentary modifier keycaps must support hold-and-press
  combos: hold Alt (or Ctrl / Shift / Win) → press another keycap → the combined report is sent.
  Dedicated ALT+TAB and WIN+L keycaps in the temporary keyboard/extended overlay must send
  exactly that combination. Single-report DECK keys (e.g. TASK VIEW) keep working. These await
  the user's physical test.
- 8. Lock-screen acceptance (main proof): from Windows, WIN+L (dedicated combined keycap) →
  lock; using ONLY the iPad: wake screen, move cursor, click, type PIN/password, log in; after
  login: Win (Start, short tap) → Alt+Tab (dedicated ALT+TAB keycap, or hold Alt + press Tab) →
  typing → scroll → left/right click. (Implemented in `ac87c61`; not yet tested on hardware —
  until then, Alt+Tab can be verified via a physical keyboard through Direct Input.)
- Ready = all mandatory items (former MVP table 1–14) work AND lock-screen acceptance passes.
- **Status: acceptance test NOT PASSED** — never fully run; awaiting the user's physical session.

## 10. Known regressions / limitations
- **Modifier behavior after `0bccedc` (fixed — contract defined in §5, implemented in `ac87c61`,
  CI-built; physical verification pending).** Verified against code + git: `0bccedc`
  ("fix: modifier keycaps send full press+release…") made modifier keycaps (Ctrl/Win/Alt/Shift)
  send full press+release (`KeyboardReport(modifiers: mod, keys: [])` + `.zero`,
  `KeyboardView.swift` ~line 279-287). This fixed the standalone Win key (before: modifier taps
  only "armed" the next key and sent NO HID report — so a lone Win press reached nothing).
  Side effect, confirmed: the old "arm" behavior is gone and the keycap model only has `.key` /
  `.modifier` actions (no chord action exists in the shipped switch) — therefore **sequential /
  2-key simultaneous combos via on-screen modifier keycaps (Ctrl+letter, Alt-then-Tab, etc.) are
  no longer sendable**. Letters were never keycaps (input field / physical keyboard only).
  Dedicated single-report DECK keys work (TASK VIEW etc.); Direct Input physical-keyboard path is
  unaffected (physical combos pass through; `DirectInputController.swift:286` builds the modifier
  bitmask). The HID stack can already send combined reports (`HIDInput.keyReports(for:modifiers:)`,
  `KeyboardReport(modifiers:keys:)`). The needed dedicated combined keycaps (ALT+TAB, WIN+L) and
  restored press-and-hold modifiers are defined in §5 (contract A–G) and §9; implemented in
  `ac87c61` [spec `d1b68d9`] — CI GREEN (run `35642707603`).
- **TOUCH mode:** EXPERIMENTAL / incomplete — absolute digitizer HID report/descriptor work not
  done; known risk to GATT descriptors/pairing (protected stack); research before implementing;
  feature flag; separate branch; owner/LEAD decision.
- **Gyro aim:** not implemented (game overlay placeholders: Touch/Gyro/Hybrid, recenter — "later").
- **Native dictation RU/EN:** not implemented (🎙 placeholder).
- **Build:** no Xcode/swift on the Windows machine — "build passes" is verified up to code
  HEAD `ac87c61` (CI run `35642707603`; earlier code HEADs: `0bccedc` / run `35511332912`,
  `7b8679d` / run `35561610311`); any newer Swift edit is unverified without a new CI run.
- `BTRemote/Resources/company_ids.json` + `service_uuids.json` are not in git (CI downloads them);
  `.xcodeproj` is generated, not committed.
- Imported upstream features out of scope here: iPhone remote surface, macOS Bluetooth Classic
  backend, TV remote (legacy `BTRemote/DPadView.swift` — no longer used by DECK).

## 11. PARKED work / non-goals
**PARKED — do not continue until a separate owner decision:** superlatency research — force BLE
7.5 ms interval, ETW/WPT Bluetooth tracing, other BT adapters, iPad Bluetooth Classic experiments,
private iOS APIs, ROG Omni reverse engineering, ESP32/RP2040 bridge, USB/Wi-Fi Turbo transport,
500/1000 Hz experiments. Reason: current BLE is usable; further latency hunting is worse ROI than
UX/features. (Also parked from earlier: MacBridge idea — verified it never existed; real
Windows→Mac build path = GitHub Actions macOS runner.)

**Non-goals / future work, not active:** Windows companion / WebSocket transport, dynamic per-app
panels, OpenClaw, clipboard / voice / state, macros, telemetry, accounts, cloud, process
monitoring. Current product is exactly: IPAD → BLE HID → WINDOWS.

**Tooling constraint:** only the current corporate Qwen model + built-in Qwen Code features; no
Codex, no Claude, no external/paid models or APIs. Project-local agents: `model: inherit`; keep
only the one `reviewer.md` profile unless a future task truly needs more.

## 12. Build and verification path
- Local: Windows; no Xcode/swift/xcodebuild — compilation cannot be checked locally. `git`/`node`
  are present; GitHub CLI `C:\LIFE\gh.exe` (authenticated as Kryptas531, token with contents
  write, verified working 2026-09-21).
- Path: Windows → `git push` (branch) → GitHub Actions workflow
  `.github/workflows/unsigned.yml` (macos-latest; bootstrap `ci_scripts/ci_post_clone.sh`:
  xcodegen via brew + download missing Nordic resource JSONs + `xcodegen generate`; build with
  commands from `build.sh` — xcodebuild `-sdk iphoneos generic/platform=iOS`,
  `CODE_SIGNING_ALLOWED=NO`; package Payload/BTRemote.app → zip → BTRemote.ipa) → artifact
  `btr-remote-unsigned-ipa` → install on the iPad via SideStore/Sideloadly (free Apple ID
  re-signing).
- Git/build values as of 2026-09-21, BEFORE the SOT-cleanup commits (verified live via git/gh):
  `main` local == remote == `7b8679d` (docs-only commit on top of code HEAD `0bccedc`); latest
  green CI: run `35561610311` (head `7b8679d`, job build-unsigned, ✓); earlier green:
  `35511332912` (head `0bccedc`). The SOT-cleanup commits (`3734cdf`/`06b8985`/`ebb5009` +
  review refresh) are docs-only on branch `cleanup/source-of-truth` — no Swift changed, so no
  new CI run is required. Newest IPA containing the Win-key fix: `.qwen/tmp/ipa-p4/BTRemote.ipa`
  (from the `0bccedc` build).
- Never commit: credentials, downloaded IPA/ZIPs, SideStore data, probes (`rawprobe/`), temp
  folders (`.qwen/tmp`), or unrelated scratch.
- Physical verification (full §9 procedure) still awaits the user's hardware sessions.

## 13. Future phase
(Not active — any of these requires a preceding spec commit per the rule at the top of this file.)
- Phase B: Windows companion / WebSocket transport (supersedes "no Windows-side software").
- Dynamic per-app panels; OpenClaw; clipboard / voice / state integrations.
- Deferred backlog: TOUCH absolute digitizer (spec commit first; feature flag; separate branch;
  BLE-stack implications to be researched), gyro aim, native dictation, modifier combined
  keycaps / sticky restore (specified in §5/§9; implemented in `ac87c61` — physical
  verification pending).
