# SPEC.md — canonical product/technical specification

**Versioned by Git SHA only. No manual Spec-Version.** This file is the single specification of
record for this repository; old docs are subordinate to current Git + this file (git history is
the archive — do not recreate `docs/archive/` or parallel roadmap/architecture/P2/layout specs).

Rule: any future change to expected behavior, architecture, UX contract, acceptance criteria or
active scope must change `SPEC.md` before implementation, in a separate spec commit. Example:
`spec(game): define gyro aim behavior` → then `feat(game): implement gyro aim [spec <sha>]`.
That cycle is now complete: spec `b9caa6d` → `1284aca` + fixes `28867db`/`aa4443c`, merged
`c89997f`. Implementation commits/PRs must reference the SPEC commit SHA they follow. Pure
fixes restoring already-specified behavior do not require a spec commit.

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
sessions — ci-worker zone). The only exception any spec commit may grant is defined in §5.1 J:
adding `NSMotionUsageDescription` to `BTRemote/Info.plist`; everything else there stays untouched.

## 5. IMPLEMENTED and CONTRACT-DEFINED behavior
(§5.1 code now EXISTS in current main — implemented per spec `b9caa6d` in `1284aca` with fixes
`28867db`/`aa4443c`; CI green run `36203590465`; merged `c89997f` via PR #10. The only
outstanding item for gyro aim is the owner's §9 hardware acceptance, not code. Swift compilation
was never possible locally — Windows without Xcode/swift — so build verification = CI only,
see §12.)
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
  through the onscreen modifier keycaps are no longer sendable (see §10). CONTRACT DEFINED
  (this spec commit); implemented with the follow-up fix below. The main onscreen modifier
  keycaps (Ctrl / Win / Alt / Shift) must behave like physical momentary modifier keys —
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
  Implemented in `dbe36ab` [spec `d1b68d9`] — build GREEN (CI run `35652625241`, job
  build-unsigned); hardware behavior stays NOT VERIFIED until the user's physical iPad +
  Windows test. History: first built in `ac87c61` (CI run `35642707603`) — superseded,
  because there an ordinary keypress released a physically held modifier.
- **Extended keys + keyboard overlay:** Insert/Delete/Home/End/PgUp/PgDn/arrows + temporary
  F1–F12 grid (`BTRemote/KeyboardView.swift`). Dedicated combined keycaps ALT+TAB and WIN+L are
  part of the contract above (they send exactly that combination via `keyReports`); they live in
  the temporary keyboard/extended overlay so the canonical DECK 4×4 stays unchanged;
  implemented in `dbe36ab` (CI run `35652625241` GREEN; physical verification pending).
  The original extended keys are IMPLEMENTED (CI VERIFIED).
  Under §7.1 E this custom panel is the temporary **Extra keys** panel and is explicitly NOT the
  iOS software keyboard.
- **DECK:** Windows control surface — shortcuts + navigation + F-keys; page 1 (COPY/PASTE/CUT/
  UNDO, TASK MGR, EXPLORER/SEARCH, TASK VIEW = Win+Tab, DESK ←/→ = Win+Ctrl+arrows, SCREENSHOT =
  Win+Shift+S, vol/mute/play-pause), page 2 (ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/HOME/END/
  PGUP/UP/PGDN/LEFT/DOWN/RIGHT/F-KEYS → temporary F-grid); swipe or buttons to switch
  (`BTRemote/RemoteView.swift`). Single-report combos work via `keyReports(for:modifiers:)`.
  IMPLEMENTED (CI VERIFIED). Under §7.1 B/C these same actions are re-homed into CONTROL's
  always-visible quick actions + the temporary **More shortcuts** panel; every action keeps the
  exact report it sends today (this bullet remains the list of record).
- **Direct Input:** a physical Windows keyboard/mouse attached to the iPad is captured through
  Game Compatible Controllers (iOS branch: `GCKeyboard.coalesced` / `GCMouse.current`,
  `DirectInputController.swift:384,391`) and forwarded to Windows as HID reports; release chord
  `Ctrl + Alt + Backspace` (`ReleaseChord.defaultChord`, `DirectInputController.swift:507`;
  configurable via `AppSettings`); fallback "Release Direct Input" button in the temporary/
  extended zone. IMPLEMENTED (CI VERIFIED; physical-keyboard pass-through not yet user-tested).
- **GAME high-fidelity input:** `touchesBegan`/`touchesMoved(_:with:)`/`touchesEnded` +
  `UIEvent.coalescedTouches(for:)` (`TouchpadView.swift:222`), chronological sample processing,
  delta from previous ACTUAL sample, predicted touches NOT used for HID mouse movement.
  TRACKPAD stays gesture-based (UIPanGestureRecognizer). IMPLEMENTED (CI VERIFIED). After §7.1
  this same gesture surface is the one hosted by CONTROL; its gesture behaviour does not change.
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
  This is the shipped state at base `3a3ddf2`; the unified **CONTROL** mode defined in §7.1
  supersedes the TRACKPAD/DECK halves of this list once implemented. Do not describe CONTROL as
  implemented before its implementation commit.

### 5.1 CONTRACT DEFINED AND IMPLEMENTED (physical acceptance pending)
Swift code for this now exists in main (implemented in `1284aca`, fixes `28867db`/`aa4443c`,
CI run `36203590465`, merged `c89997f`); the A–L clauses below remain the contract of record
(spec-first rule at the top of this file; spec commit `b9caa6d`).
- **A. Scope:** GAME mode only. Touch remains the default GAME input and its current behavior
  (see "GAME high-fidelity input" above) must stay unchanged. This GAME-only gyro contract is not
  changed by §7.1: the former TRACKPAD gestures stay exactly as they are and simply become
  CONTROL's pad behavior, the former DECK reports and actions are rehomed inside CONTROL unchanged,
  and TOUCH remains the experimental, unaffected path.
- **B. Gyro:** map device-attitude increments (the delta from the previously used attitude) to
  cursor movement — relative HID mouse `dx`/`dy` sent through the existing relative-mouse report
  path. No new HID report type, no absolute digitizer. When the mode is Gyro, touch movement is
  disabled, but the existing GAME single-finger tap-to-LMB must keep working exactly as it does
  today (`HighFidelityTouchView.finish(_:)` fires `onTap`, which is `HIDInput.click(.left)`).
  No two-finger-tap-to-RMB handler exists on the GAME path, and this contract does not require,
  claim or introduce any right-click behavior.
- **C. Sensitivity:** gyro sensitivity is HID mouse counts per radian of device rotation;
  default **180**, adjustable range **20–600**. Touch sensitivity keeps its existing meaning
  and default.
- **D. Hybrid:** touch and gyro are computed independently. Each source's deltas are scaled by
  its own sensitivity (touch by the existing touch sensitivity, gyro by the gyro sensitivity) and
  are delivered through the existing relative-mouse report path as they arrive — there is no
  shared cycle and neither source waits for the other. The resulting cursor displacement is
  simply the vector sum of both streams over time. Neither source cancels or replaces the other,
  and existing touch behavior (movement and single-finger tap-to-LMB) stays intact. No cadence
  synchronization, smoothing, filtering, interpolation or any other artificial processing is
  allowed between the two sources.
- **E. Axis mapping (landscape, screen-relative):** horizontal rotation maps to positive (right)
  `dx`; vertical rotation maps to positive (down) `dy`.
- **F. Recenter:** set the previous-attitude baseline to the current attitude; recentering itself
  emits no movement.
- **G. Activation / resume:** on gyro activation, and when the app returns to GAME or becomes
  active again, the current attitude becomes the baseline — stale deltas are never replayed.
- **H. Motion unavailable:** produce no gyro delta, show an "unavailable" status in the temporary
  GAME chrome, and keep touch movement active in Hybrid.
- **I. Controls:** mode (Touch / Gyro / Hybrid), sensitivity, gyro sensitivity and recenter are
  exposed only in the temporary GAME chrome (§7); no permanent panels, no new telemetry.
- **J. Boundaries:** do not change Direct Input, and do not change the protected BLE/HID boundary
  (§4) — gyro output reuses the existing relative mouse report path. The single permitted
  protected-file exception is adding **only** `NSMotionUsageDescription` to `BTRemote/Info.plist`
  with exactly the text `BTRemote uses device motion to control the mouse in GAME mode.`
  (technically required for CoreMotion device attitude; the key is absent as of `dbe36ab`).
  That key requires focused review. `BTRemote/entitlements.plist`, `BTRemote/LowEnergy/`,
  `BTRemote/Classic/`, `BTRemote/HIDInput.swift` and `BTRemote/HIDReports.swift` stay untouched.
- **K. No artificial smoothing, filtering or latency** may be added to the input pipeline.
- **L. Verification:** implementation may claim CI only. Do not claim gyro aim works until the
  owner has run the §9 hardware acceptance including GAME gyro; until then it stays
  "implemented, physical verification pending".

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
details from git history if needed; do not recreate these files. §7.1 supersedes the parts of this
section that assume separate TRACKPAD / DECK top-level modes; nothing else in §7 is weakened.)
- Primary device: iPad Air 11" M2 2024. The Windows-input surface must be usable in BOTH
  orientations (§7.1 F); landscape stays the orientation the §5/§6 measurements were taken in.
  Idea: maximum input surface, minimum permanent controls.
- Very compact top bar `[GAME | CONTROL | TOUCH]` + tiny indicators (`●BT ⌨`); top bar can
  auto-hide in GAME. Settings = modal/sheet, not a big tab.
  - SUPERSEDED wording (this line used to read `[GAME | TRACKPAD | TOUCH | DECK]`): there is no
    separate TRACKPAD mode and no separate DECK mode any more — one **CONTROL** mode replaces both
    (§7.1 A). GAME stays separate; TOUCH stays the experimental/disabled placeholder.
- No large permanent CONNECTED / DIRECT INPUT / debug / setup-status panels and no long status
  texts; connection/Direct Input = tiny indicators only.
- Trackpad stays the visual and interactive centre of the Windows-input surface and keeps the
  dominant share of the useful area (≈85–90 % of it in landscape); no permanent wide right
  sidebar / scroll column / L-M-R rows. The single permitted exception is the small always-visible
  quick-action set around the pad (§7.1 B) — a compact edge/ring strip of existing actions, never
  a wide sidebar, never a second full-screen surface, never the multi-row fixed keyboard.
  Custom extended keys ("Extra keys") open as temporary overlays and never shrink the trackpad
  permanently.
- GAME ≈ fullscreen input surface; controls (Touch/Gyro/Hybrid, sensitivity, gyro sensitivity,
  recenter, debug toggle) only as temporary overlay; optional LMB/RMB zones semi-transparent/
  configurable/removable; do not draw a WASD keyboard (external physical keyboard assumed).
- TOUCH ≈100 % surface, controls hidden, edge gestures only (EXPERIMENTAL).
- DECK is no longer a separate full-screen page: it is the Windows control action set hosted
  inside CONTROL (always-visible quick actions + temporary "More shortcuts", §7.1 B/C). DECK
  remains a Windows control surface, not the old media/TV remote, and its action list and HID
  reports (§5 "DECK") are unchanged.
- Direct Input: compact status icon; capture/release controls via long-press on keyboard
  indicator or in settings; a physical Windows keyboard must keep working as is.
- Dictation: small 🎙 push-to-dictate button, temporary transcript not covering the central
  trackpad (not implemented — placeholder; NOT part of the §7.1 contract, see §8 stage 5).
- All touch buttons: immediate pressed visual state (+ short click sound if enabled; toggle
  ON/OFF visually clear); never add latency to the input pipeline for animations. Every always-
  visible CONTROL control must stay reachable in both orientations and must not cover the
  trackpad's free touch area (only button hit areas may intercept).
- Working rule from past sessions: first INSPECT the current implementation, minimal layout
  refactor over existing working views, preserve all implemented features, working input paths,
  Direct Input, current CI and BLE behavior.

## 7.1 Unified CONTROL mode — CONTRACT DEFINED, NOT YET IMPLEMENTED
Spec-first contract for the operator-requested unified iPad control UX. Defined at base
`3a3ddf2`; no Swift, README or other file is changed by this spec commit. The implementation
commit must reference this spec SHA. Nothing here changes any HID report, keycode, gesture,
Direct Input path or the protected boundary (§4 / §5.1 J) — only the surface that hosts existing
actions moves.
- **A. One mode.** One top-level mode **CONTROL** replaces the separate TRACKPAD and DECK modes.
  Name chosen: `CONTROL` — concise and accurate (this one surface is where the iPad controls
  Windows: trackpad + shortcuts + text entry), whereas `TRACKPAD` wrongly implied a trackpad-only
  surface and `DECK` was a second destination for the same job. Top bar: `GAME | CONTROL | TOUCH`.
  GAME keeps today's behaviour and its temporary GAME chrome exactly as implemented (§5, §5.1).
  TOUCH stays the experimental/disabled placeholder. No screen may present a second full-screen
  DECK surface, and no workflow may require a mode switch to reach the trackpad or a shortcut.
  Upgrade rule (testable): a previously persisted TRACKPAD or DECK mode selection must migrate to
  CONTROL on first launch after this change, so an existing install never opens into a blank or
  invalid mode; unrelated persisted app settings are preserved unchanged.
- **B. Always-live pad + reachable shortcuts.** CONTROL always presents the live central trackpad
  and reachable DECK shortcuts at the same time in the same mode. Always-visible quick-action set
  (concrete, existing actions and existing reports only, no new keycodes, no new reports):
  `COPY` (Ctrl+C), `PASTE` (Ctrl+V), `CUT` (Ctrl+X), `UNDO` (Ctrl+Z), `ALT+TAB`, `WIN+L`,
  `SEARCH` (Win+S), `PLAY/PAUSE` (consumer). Small icon/label buttons only — never a full keycap
  keyboard and never wide enough to pull the pad away from the centre.
- **C. Everything else stays reachable, temporarily.** All remaining DECK actions — page 1
  (TASK MGR, EXPLORER, DESK, DESK ←/→, SCREENSHOT, VOL−, MUTE, VOL+), page 2 (ESC, TAB, ENTER,
  BACKSPACE, INSERT, DELETE, HOME, END, PGUP, UP, PGDN, LEFT, DOWN, RIGHT, F-KEYS → the temporary
  F1–F12 grid) and the page-switch control itself — remain reachable from one temporary
  **"More shortcuts"** panel opened from CONTROL, without leaving CONTROL. Same action → same
  report (single-report `keyReports(for:modifiers:)` / `sendConsumer`) as listed in §5 "DECK".
- **D. Touch-through.** The trackpad stays the visual and interactive centre and its free surface
  must remain touchable: only actual button/control hit areas may intercept touches. Decorative
  material behind controls must not participate in hit testing (reuse the existing
  `.allowsHitTesting(false)` treatment from the GAME chrome); a control layer must never swallow
  pad gestures.
- **E. Custom key panel ≠ iOS software keyboard.** The app's custom extended-key panel
  (Ctrl/Win/Alt/Shift hold + ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/HOME/END/PGUP/PGDN/arrows/
  F1–F12 + ALT+TAB/WIN+L) is a distinct thing from the iOS software keyboard. It is closed by
  default and toggled by one clearly labelled **"Extra keys"** control that also carries an
  explicit close/toggle affordance. Toggling Extra keys must not set TextField focus and must not
  summon the native iOS keyboard. Only focusing/tapping the text-entry field may summon the system
  keyboard; text-entry, live-typing, Send/Clear and the §5 A–G modifier semantics stay unchanged
  (whatever panel holds the modifiers must also hold the keys they combine with, so hold-Alt-then-
  press-Tab and the dedicated ALT+TAB / WIN+L keycaps still work while that panel is open).
  Mutual exclusion (predictable, avoids both panels covering the pad): opening "Extra keys" while
  the native keyboard is up dismisses the native keyboard (focus cleared) so only Extra keys is
  shown; tapping/focusing the text-entry field while Extra keys is open closes Extra keys so only
  the system keyboard is shown. At most one of the two panels is ever visible.
- **F. Responsive orientation.** Landscape: pad central with the compact action controls at the
  outer edges. Portrait: pad centred/largest with the compact controls above and below. No huge
  permanent sidebar, no mode-specific full-screen switch, no cluttered fixed keyboard above the
  pad (the multi-row keycap panel and the always-visible bottom strip become the temporary
  "Extra keys" panel). All existing trackpad gestures (1-finger move, tap → LMB, two-finger move
  → scroll, two-finger tap → RMB, drag) and all existing DECK key reports must be preserved
  exactly.
- **G. Verification / limits.** Implementation may claim CI only; behaviour stays "implemented,
  physical verification pending" until the owner runs the §9 checks in both orientations. No
  dictation work is included here (still §8 stage 5 / §13).

## 8. Active milestone
Per the reconciled roadmap (2026-09-20/21, renumbered for §7.1):
1. Unified CONTROL surface — UX canon (§7) + unified control contract (§7.1); this absorbs the
   former stages "TRACKPAD usability" and "DECK", which no longer exist as separate modes
2. GAME usability → 3. Direct Input / Windows keyboard semantics → 4. Gyro aim → 5. Native
dictation RU/EN → 6. Feedback → 7. experimental TOUCH / absolute digitizer.

Implemented: **modifier hold + combined keycaps after `0bccedc`** — contract defined in §5
(A–G, spec `d1b68d9`); implemented in `dbe36ab`, CI GREEN (run `35652625241`).
Remaining: the user's physical verification per §9.

Stage **4. Gyro aim** is implemented — contract defined in §5.1 (spec `b9caa6d`); code in
`1284aca` with fixes `28867db`/`aa4443c`; CI green run `36203590465`; merged `c89997f` via
PR #10. The owner's §9 hardware acceptance for it is still outstanding. Stage **1. Unified
CONTROL surface** is specified but **not implemented** (§7.1); the next unstarted roadmap stage
after it is **5. Native dictation RU/EN** — per §13 this requires its own preceding spec commit
(no dictation contract is written here).

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
- 4. CONTROL/trackpad gestures (there is no separate TRACKPAD mode after §7.1): 1-finger move,
  tap → LMB, two-finger move → scroll, two-finger tap → RMB, drag; GAME raw movement path tested
  separately (high-rate input must not drop deltas).
- 5. Performance metrics: developer mode, GAME, continuous movement ≥10 s; record touch Hz, raw
  samples Hz, mouse generated Hz, BLE accepted Hz, backpressure, pending, coalesced, lost delta,
  avg/max interval. CI cannot infer these.
- 6. Keyboard: typing via input field reaches Windows; ESC/ENTER keycaps work.
- 7. Shortcuts: Win tap → Start opens. Momentary modifier keycaps must support hold-and-press
  combos: hold Alt (or Ctrl / Shift / Win) → press another keycap → the combined report is sent.
  Dedicated ALT+TAB and WIN+L keycaps in the temporary keyboard/extended overlay ("Extra keys",
  §7.1 E) must send exactly that combination. Single-report DECK keys (e.g. TASK VIEW) keep
  working. These await the user's physical test.
- 8. Lock-screen acceptance (main proof): from Windows, WIN+L (dedicated combined keycap) →
  lock; using ONLY the iPad: wake screen, move cursor, click, type PIN/password, log in; after
  login: Win (Start, short tap) → Alt+Tab (dedicated ALT+TAB keycap, or hold Alt + press Tab) →
  typing → scroll → left/right click. (Implemented in `dbe36ab`; not yet tested
  on hardware — until then, Alt+Tab can be verified via a physical keyboard through
  Direct Input.)
- 9. Unified CONTROL surface (repeat items 4–7 in EACH orientation, landscape and portrait):
  (a) no separate TRACKPAD or DECK top-level mode exists — top bar is `GAME | CONTROL | TOUCH`;
  (b) the central touchpad and the compact quick actions are visible together, pad central (and
  largest) with actions on the outer edges in landscape / above and below in portrait;
  (c) every existing DECK shortcut and F-key is still reachable — spot-check COPY, PASTE, CUT,
  UNDO, ALT+TAB, WIN+L, SEARCH, PLAY/PAUSE from the always-visible set, and TASK MGR, EXPLORER,
  DESK, DESK ←/→, SCREENSHOT, VOL−, MUTE, VOL+, ESC, TAB, ENTER, BACKSPACE, INSERT, DELETE,
  HOME, END, PGUP, UP, PGDN, LEFT, DOWN, RIGHT and F1–F12 from "More shortcuts" — and each still
  reaches Windows;
  (d) trackpad gestures from item 4 still work in the pad's free areas while controls are present;
  (e) "Extra keys" opens the custom panel, does NOT summon the iOS keyboard, and closes explicitly
  via its own affordance;
  (f) tapping the text-entry field DOES summon the system keyboard and typing still reaches
  Windows;
  (g) opening "Extra keys" while the native keyboard is up leaves exactly one panel visible;
  (h) GAME behaviour is unchanged.
- Ready = all mandatory items (former MVP table 1–14) plus item 9 work AND lock-screen acceptance
  passes.
- **Status: acceptance test NOT PASSED** — never fully run; awaiting the user's physical session.

## 10. Known regressions / limitations
- **Modifier behavior after `0bccedc` (fixed — contract defined in §5, implemented in
  `dbe36ab`, CI-built; physical verification pending).** Verified against code + git:
  `0bccedc`
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
  `dbe36ab` [spec `d1b68d9`] — CI GREEN (run `35652625241`); first built in `ac87c61`
  (CI `35642707603`, superseded by the held-modifier correction in `dbe36ab`).
- **TOUCH mode:** EXPERIMENTAL / incomplete — absolute digitizer HID report/descriptor work not
  done; known risk to GATT descriptors/pairing (protected stack); research before implementing;
  feature flag; separate branch; owner/LEAD decision.
- **Gyro aim:** implemented (SPEC §5.1; commits `1284aca` + fixes `28867db`/`aa4443c`; CI green
  run `36203590465`; merged `c89997f`) — physical verification pending per §5.1 L / §9.
  `BTRemote/Info.plist` now contains `NSMotionUsageDescription` with exactly the text
  `BTRemote uses device motion to control the mouse in GAME mode.` (the single protected-file
  exception §5.1 J allows).
- **Unified CONTROL surface (§7.1):** spec-defined only, NOT implemented — the shipped app still
  has separate TRACKPAD and DECK modes (`BTRemote/KeyboardView.swift`, `BTRemote/RemoteView.swift`
  at `3a3ddf2`); implementation must follow this spec commit.
- **Native dictation RU/EN:** not implemented (🎙 placeholder).
- **Build:** no Xcode/swift on the Windows machine — "build passes" is verified up to code
  HEAD `aa4443c` (CI run `36203590465`; earlier code HEADs: `dbe36ab` / run `35652625241`,
  `ac87c61` / run `35642707603`, `0bccedc` / run `35511332912`, `7b8679d` / run `35561610311`);
  any newer Swift edit is unverified without a new CI run.
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
Codex, no Claude, no external/paid models or APIs. The final reviewer (`.qwen/agents/reviewer.md`)
explicitly pins `model: openai-responses:Qwen/Qwen3.8-Flash-Next` and must never inherit the
generic/no-thinking default worker route; other project-local agents may use `model: inherit`
per current QWEN/task routing. Keep only the one `reviewer.md` profile unless a future task
truly needs more.

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
- Git/build values as of 2026-09-21, BEFORE the SOT-cleanup commits (dated historical snapshot,
  verified live via git/gh at that time):
  `main` local == remote == `7b8679d` (docs-only commit on top of code HEAD `0bccedc`); latest
  green CI: run `35561610311` (head `7b8679d`, job build-unsigned, ✓); earlier green:
  `35511332912` (head `0bccedc`). The SOT-cleanup commits (`3734cdf`/`06b8985`/`ebb5009` +
  review refresh) are docs-only on branch `cleanup/source-of-truth` — no Swift changed, so no
  new CI run is required. Newest IPA containing the Win-key fix: `.qwen/tmp/ipa-p4/BTRemote.ipa`
  (from the `0bccedc` build).
- Current verified facts (2026-09-26): `main` local == `origin/main` == `c89997f`; newest green
  "Build unsigned IPA" run `36203590465` at head `aa4443c`; newest IPA = that run's artifact
  `btr-remote-unsigned-ipa`.
- Never commit: credentials, downloaded IPA/ZIPs, SideStore data, probes (`rawprobe/`), temp
  folders (`.qwen/tmp`), or unrelated scratch.
- Physical verification (full §9 procedure) still awaits the user's hardware sessions.

## 13. Future phase
(Not active — any of these requires a preceding spec commit per the rule at the top of this file.)
- Phase B: Windows companion / WebSocket transport (supersedes "no Windows-side software").
- Dynamic per-app panels; OpenClaw; clipboard / voice / state integrations.
- Deferred backlog: TOUCH absolute digitizer (spec commit first; feature flag; separate branch;
  BLE-stack implications to be researched), gyro aim (implemented and CI-verified in `1284aca`
  + fixes `28867db`/`aa4443c`, CI run `36203590465`; physical acceptance pending per §5.1 L /
  §9), native dictation, modifier combined keycaps / sticky restore (specified in §5/§9;
  implemented in `ac87c61` + `dbe36ab` — physical verification pending).
