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
sessions — ci-worker zone). The only exceptions any spec commit may grant are: adding
`NSMotionUsageDescription` to `BTRemote/Info.plist` (§5.1 J), and adding
`NSLocalNetworkUsageDescription` to `BTRemote/Info.plist` with exactly the text
`BTRemote connects to your paired Windows PC on the local network to show app-specific controls.` (§7.2). No other
key may be added there and everything else in those two files stays untouched.

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
- **Extended keys + keyboard overlay:** Insert/Delete/Home/End/PgUp/PgDn/arrows/SPACE/PRTSC +
  right-side Ctrl/Alt Gr/Shift/Win modifier keycaps + temporary F1–F12 grid, plus the bottom
  strip Ctrl/Win/Alt/Shift + ESC/TAB/ENTER + the panel toggle (`BTRemote/KeyboardView.swift`).
  No shipped control may be dropped from this inventory. Dedicated combined keycaps ALT+TAB and
  WIN+L are part of the contract above (they send exactly that combination via `keyReports`);
  they live only in this custom panel, so the canonical DECK 4×4 stays unchanged and those two
  combined keycaps are not duplicated in the always-visible quick-action set (§7.1 B);
  implemented in `dbe36ab` (CI run `35652625241` GREEN; physical verification pending).
  The original extended keys are IMPLEMENTED (CI VERIFIED).
  Under §7.1 E this custom panel is the temporary **Extra keys** panel and is explicitly NOT the
  iOS software keyboard, and it is a different panel from the §7.1 C **More shortcuts** panel.
- **DECK:** Windows control surface — shortcuts + navigation + F-keys; page 1 (COPY/PASTE/CUT/
  UNDO, TASK MGR, EXPLORER/SEARCH/DESKTOP, TASK VIEW = Win+Tab, DESK ←/→ = Win+Ctrl+arrows,
  SCREENSHOT = Win+Shift+S, vol/mute/play-pause), page 2 (ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/
  HOME/END/PGUP/UP/PGDN/PRTSC/LEFT/DOWN/RIGHT/F-KEYS → temporary F-grid); swipe or buttons to
  switch (`BTRemote/RemoteView.swift`). Single-report combos work via `keyReports(for:modifiers:)`.
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
  supersedes the TRACKPAD/DECK halves of this list. CONTROL is now implemented (code `fd50ae1`
  [spec `97d459b`], merged `482155b` via PR #17); physical verification stays pending per §9.

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
  (§4) — gyro output reuses the existing relative mouse report path. One permitted
  protected-file exception is adding **only** `NSMotionUsageDescription` to `BTRemote/Info.plist`
  with exactly the text `BTRemote uses device motion to control the mouse in GAME mode.`
  (technically required for CoreMotion device attitude; the key is absent as of `dbe36ab`); the
  other permitted exception is `NSLocalNetworkUsageDescription` as defined in §4/§7.2.
  Both keys require focused review. `BTRemote/entitlements.plist`, `BTRemote/LowEnergy/`,
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
  permanently. "Extra keys" (custom keyboard panel) and "More shortcuts" (full DECK panel) are two
  distinct panels with separate entry controls; only one of them may be open at a time.
- GAME ≈ fullscreen input surface; controls (Touch/Gyro/Hybrid, sensitivity, gyro sensitivity,
  recenter, debug toggle) only as temporary overlay; optional LMB/RMB zones semi-transparent/
  configurable/removable; do not draw a WASD keyboard (external physical keyboard assumed).
- TOUCH ≈100 % surface, controls hidden, edge gestures only (EXPERIMENTAL).
- DECK is no longer a separate full-screen page: it is the Windows control action set hosted
  inside CONTROL (always-visible quick actions + temporary "More shortcuts", §7.1 B/C; this is not
  the custom "Extra keys" keyboard panel, §7.1 E). DECK remains a Windows control surface, not the
  old media/TV remote, and its action list and HID reports (§5 "DECK") are unchanged.
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

## 7.1 Unified CONTROL mode — CONTRACT DEFINED AND IMPLEMENTED (physical acceptance pending)
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
  `COPY` (Ctrl+C), `PASTE` (Ctrl+V), `CUT` (Ctrl+X), `UNDO` (Ctrl+Z), `TASK VIEW` (Win+Tab),
  `SCREENSHOT` (Win+Shift+S), `SEARCH` (Win+S), `PLAY/PAUSE` (consumer). Small icon/label buttons
  only — never a full keycap keyboard and never wide enough to pull the pad away from the centre.
  `ALT+TAB` and `WIN+L` are deliberately NOT in this set: they are combined keycaps belonging to
  the custom keyboard panel (§7.1 E) and the always-visible set must stay a subset of existing
  DECK reports (§5 "DECK").
- **C. Everything else stays reachable, temporarily.** **"More shortcuts"** is one single temporary
  panel that shows the whole remaining DECK surface: page 1 (TASK MGR, EXPLORER, DESKTOP,
  DESK ←/→, VOL−, MUTE, VOL+) and page 2 (ESC, TAB, ENTER, BACKSPACE, INSERT, DELETE, HOME, END,
  PGUP, UP, PGDN, PRTSC, LEFT, DOWN, RIGHT, F-KEYS → the temporary F1–F12 grid) and the page-switch
  control itself — all still reachable from CONTROL, without leaving CONTROL and without dropping
  any shipped control. Same action → same report (single-report `keyReports(for:modifiers:)` /
  `sendConsumer`) as listed in §5 "DECK". The actions that also sit in the always-visible
  quick-action set (B) appear in both places; that duplication is intentional.
  "More shortcuts" (DECK panel) and "Extra keys" (custom keyboard panel, E) are **two distinct
  panels with separate entry controls** — neither may be implemented or labelled as the other, and
  only one of the two may be open at a time: opening one closes the other. Overlap between them is
  intentional and must not be "cleaned up": the custom panel deliberately repeats the common
  navigation keys (ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/HOME/END/PGUP/PGDN/arrows/SPACE/PRTSC/
  F1–F12) because those keycaps have to sit in the same panel as the modifiers they combine with
  (§5 A–G).
- **D. Touch-through.** The trackpad stays the visual and interactive centre and its free surface
  must remain touchable: only actual button/control hit areas may intercept touches. Decorative
  material behind controls must not participate in hit testing (reuse the existing
  `.allowsHitTesting(false)` treatment from the GAME chrome); a control layer must never swallow
  pad gestures.
- **E. Text entry ≠ custom key panel ≠ iOS software keyboard ≠ "More shortcuts".** Two things
  that today share one screen must stay separate:
  - **Text entry** — the shipped text-entry field with Send/Clear (`KeyboardView` `TextField` +
    `KeyTypist` + `HIDInput.type(char)`, §4/§5 "Keyboard"). It is **independent of the custom
    keycap panel**: the field is not embedded in it, and it must stay reachable without ever
    opening that panel. Text entry is its own temporary surface, opened by its own clearly
    labelled, always-reachable **"Text entry"** control (a third entry control next to
    "More shortcuts" and "Extra keys"; no mode switch needed to reach it).
  - **Extra keys** — the app's custom extended-key panel (Ctrl/Win/Alt/Shift hold + right-side
    Ctrl/Alt Gr/Shift/Win + ESC/TAB/ENTER/BACKSPACE/INSERT/DELETE/HOME/END/PGUP/PGDN/arrows/
    SPACE/PRTSC + F1–F12 + ALT+TAB/WIN+L, together with the bottom strip Ctrl/Win/Alt/Shift +
    ESC/TAB/ENTER + the panel toggle). It is a distinct thing from the iOS software keyboard, and a
    distinct thing from the §7.1 C "More shortcuts" DECK panel. It is closed by default and toggled
    by one clearly labelled **"Extra keys"** control that also carries an explicit close/toggle
    affordance. It contains **only** the shipped custom keycaps listed above — no embedded text
    field, no embedded Send/Clear. No shipped keycap listed above may be omitted.
  Text entry, live-typing, Send/Clear and the §5 A–G modifier semantics stay unchanged (whatever
  panel holds the modifiers must also hold the keys they combine with, so hold-Alt-then-press-Tab,
  the right-side modifiers, SPACE, PRTSC and the dedicated ALT+TAB / WIN+L keycaps still work while
  that panel is open).
  Opening a surface and focusing a field are different events. **Opening** the "Text entry" surface
  alone must not force focus into the field and must not summon the iOS keyboard: the field stays
  visible on the surface and the user taps it. Only **tapping/focusing** that separate field may
  summon the system keyboard. Auto-focusing the field when the surface opens is allowed only if
  this spec explicitly specifies it and the behaviour is user-visible; it is not specified here.
  **The "Extra keys" toggle must never focus the TextField, must never open "Text entry", and must
  never summon the native iOS keyboard.**
  Mutual exclusion (predictable, avoids two panels covering the pad): opening "Text entry" closes
  "Extra keys" and closes "More shortcuts"; opening "Extra keys" while the native keyboard is up
  dismisses the native keyboard (focus cleared) so only Extra keys is shown; tapping/focusing the
  text-entry field while Extra keys is open closes Extra keys so only the system keyboard is shown;
  opening "Extra keys" while "More shortcuts" is open closes "More shortcuts", and vice versa. At
  most one of the three app surfaces ("Text entry"/native keyboard, "More shortcuts", "Extra keys")
  is ever visible — but the "Text entry" field and the OS keyboard are one workflow, not two
  competing panels: once the field is focused, the field must stay present and usable while the
  iOS software keyboard is visible, so live typing, Send and Clear can still be used above it.
- **F. Responsive orientation.** Landscape: pad central with the compact action controls at the
  outer edges. Portrait: pad centred/largest with the compact controls above and below. No huge
  permanent sidebar, no mode-specific full-screen switch, no cluttered fixed keyboard above the
  pad (the multi-row keycap panel and the always-visible bottom strip both become the temporary
  "Extra keys" panel). All existing trackpad gestures (1-finger move, tap → LMB, two-finger move
  → scroll, two-finger tap → RMB, drag) and all existing DECK key reports must be preserved
  exactly.
- **G. Verification / limits.** Implementation may claim CI only; behaviour stays "implemented,
  physical verification pending" until the owner runs the §9 checks in both orientations. No
  dictation work is included here (still §8 stage 5 / §13).

## 7.2 Windows helper and foreground-aware layouts — CONTRACT DEFINED; IMPLEMENTED IN `c8babce` (CI build and physical acceptance pending)
Spec-first contract for the owner-approved optional Windows helper that tells the iPad which
application is in the foreground so the iPad can present an app-specific CONTROL layout. This is
the previously non-goaled "Windows companion / WebSocket transport" and "dynamic per-app panels"
work (§11, §13), now approved and specified. Defined at base `482155b`; no Swift, README or other
file was changed by that spec commit. The implementation is committed in `c8babce`
(`feat(windows): configure foreground app layouts [spec fb77782]`): the §7.2 F configurability gap
found by the independent review is closed — the executable→layout map and every
layout's labelled actions are one user-editable JSON document instead of hard-coded Swift action
sets, and the Swift 6 strict-concurrency problem in `AppLayouts` is gone. The code being committed
does not mean it is verified: no CI job has built the Swift client yet and no hardware test has been
run (§7.2 I, §9 item 10).

Core principle: **the BLE HID input path (§1/§3/§4/§5) is retained and is the only input channel.**
The helper is out-of-band UI signalling only. It reports a foreground-app identity so the iPad knows
which layout to show; it does not send HID input, does not replace or re-negotiate BLE/HOGP pairing,
and is never required for basic mouse / keyboard / trackpad / Direct-Input control. If the helper is
absent the device behaves exactly as §7.1 defines. §7.1 (unified CONTROL) must be implemented before
this; each layout below is a variant of that same CONTROL surface, not a new mode or a new surface.

- **A. Product addition.** A small Windows-side companion app ("the helper") runs on the Windows PC,
  detects the application that currently owns the foreground window, and reports a stable identity
  for it to the paired iPad. The iPad then swaps its CONTROL panel to the matching app-specific
  layout. Additive convenience only; no shipped feature, input path, HID report or key may be
  removed or changed to accommodate it.
- **B. Secure local communication.** Helper and iPad talk only over the local network (same LAN /
  Wi-Fi). The helper binds exactly one concrete, operational, non-tunnel **private/local IPv4
  unicast** address (loopback, RFC 1918, or link-local) on the configured port (default **8443**,
  optional first command-line argument), and refuses to start when no such interface exists; it must
  never listen on a public/Internet-facing, wildcard (`0.0.0.0` / `::`) or tunnel address.
  The channel is encrypted and authenticated end to end over **TLS** carrying **WebSocket** text
  frames: the iPad connects to `wss://<private-IPv4>:<port>` and the helper completes the RFC 6455
  server handshake (Sec-WebSocket-Key/Accept) over the established TLS stream. No plaintext
  transport exists anywhere in the helper and none is permitted.
  The TLS endpoint uses a runtime-generated **self-signed** certificate (`CN=ipad-foreground-helper`,
  RSA 2048, SHA-256, 30 days), persisted so the same key pair — and therefore the same **SHA-256
  certificate fingerprint** — survives helper restarts. The iPad trust-on-first-use **pins** that
  fingerprint: it accepts the certificate only when the SHA-256 digest of the leaf certificate
  equals the fingerprint the helper printed and the user entered in iPad settings, and cancels the
  authentication challenge otherwise. If the persisted certificate becomes unusable the helper
  regenerates one and the iPad must re-pin the new fingerprint.
  **Auth before notifications:** the helper sends no application data whatsoever until the
  connecting device has proved possession of the credential defined in C. After that exchange the
  only message it ever sends is the single notification
  `{"type":"foreground-changed","identity":"<token>"}` (tokens `vscode` | `chrome` | `explorer` |
  `generic`, §D/§E; the helper re-sends it only when the resolved identity changes, polling the
  foreground window every 350 ms). It never sends HID reports, keystrokes, shortcuts, commands,
  window titles, executable paths or arbitrary process data.
  The channel is **unidirectional for control**: one helper instance serves one paired iPad at a
  time, and the link never carries input in either direction. All input continues to flow
  iPad → Windows over the existing BLE HID path.
- **C. Secure local pairing (pair → secret → reconnect).** One-time local pairing between the
  helper and the target iPad, done on the same LAN. The wire exchange is exactly the following, and
  nothing in the implementation may invent other message types or fields:
  1. The helper binds its local endpoint, prints the certificate **SHA-256 fingerprint** and a
     cryptographically random **six-digit one-time pairing code** (`000000`–`999999`) on the local
     Windows console, and waits for the iPad. A code is only meaningful while no valid stored secret
     exists; the auth mode is fixed at helper start, so the console output and the credential the
     server will accept can never disagree.
  2. The user enters the Windows private address, port, fingerprint and code in the iPad's
     **Windows helper** settings section and taps **Connect**. The iPad opens the TLS/WebSocket
     connection and sends its credential **first**, the exact frame
     `{"type":"pair","code":"<code>"}`, inside the helper's 5-second window (one frame, ≤64 bytes).
  3. On a successful pair the helper generates the long-lived **256-bit (32-byte) device secret**,
     persists it DPAPI-protected for the current Windows user
     (`%LOCALAPPDATA%\iPadForegroundHelper\device-secret.bin`, `CryptProtectData`, never as
     plaintext), and hands it to the iPad **once**, over the already-established TLS channel, as
     `{"type":"paired","secret":"<base64>"}`. The one-time code is now spent and is never accepted or
     reprinted.
  4. On every later connection (helper restart, Wi-Fi drop, iPad reboot, or a reconnect after the
     helper lost the previous socket) the iPad authenticates with
     `{"type":"reconnect","secret":"<base64>"}` and the helper replies `{"type":"reconnected"}` — no
     new code is issued, entered or accepted. A real 32-byte secret base64-encodes to 44 characters,
     so that exact frame is 76 bytes; the helper therefore reads one bounded authentication frame of
     at most `MaxAuthFrameBytes` = 128 bytes (bounded allocation, no unbounded read). The helper
     verifies the credential against its own expected request with a fixed-time comparison, so the
     device never has to re-enter a code the helper no longer prints; a device reconnecting on a
     fresh socket replaces the stale one.
  The endpoint rejects any peer that does not present that credential: a connection that fails TLS,
  the WebSocket handshake, or credential verification is closed without a single byte of payload and
  leaves any previously authenticated session untouched.
  **Re-pairing recovery (read this before telling the user to restart the helper).** While a valid
  32-byte secret is persisted on Windows, restarting the helper does NOT issue or print a fresh
  pairing code: the helper stays in reconnect mode and only accepts the stored secret, so a
  restarted helper that says "device secret already stored; waiting for the iPad to reconnect with it
  (no new pairing code is issued)" is behaving correctly. To pair a *different* iPad, the user must
  tap **"Unpair and forget this helper"** on the iPad (which clears its Keychain secret) AND delete
  only `%LOCALAPPDATA%\iPadForegroundHelper\device-secret.bin` on Windows, then restart the helper;
  it then prints a fresh one-time code. Keep `%LOCALAPPDATA%\iPadForegroundHelper\tls-cert.pfx` in
  place so the pinned certificate and its fingerprint survive the re-pair. If that certificate is
  deliberately removed or regenerated, the helper prints a new SHA-256 fingerprint and it must be
  re-entered on the iPad. Until the device-secret file has been removed and the helper restarted, a
  new/unpaired iPad cannot pair at all.
  The iPad keeps the helper-issued 32-byte secret in the **iOS Keychain only** (generic password,
  service `io.github.jqssun.btremote.windows-foreground`, account `device-secret`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); host, port and fingerprint are ordinary app
  settings and the secret is never stored with them. "Unpair and forget this helper" clears it.
  Storage is **fail-closed**: if the secret cannot be written the iPad reports an error and stays on
  the §7.1 generic layout instead of claiming a link it could not re-authenticate later.
  The one-time pairing code is deliberately displayed to the user, not hidden: `Program.Main` prints
  it on the local Windows console as `[windows-foreground] one-time pairing code: <code>` so the user
  can type it into the iPad. It is a transient user-interface affordance, not a stored credential:
  it is never persisted (no file, no UserDefaults, no Keychain) and never sent to any third party or
  to any non-local destination. The long-lived device secret is never printed anywhere (the helper
  only says that a secret was issued and stored); it crosses the wire exactly once, inside the TLS
  `{"type":"paired",...}` frame, and afterwards exists only in the helper's DPAPI-protected file and
  the iPad Keychain. Neither the code nor the secret is ever committed to git (the §12 "never commit
  credentials" rule applies).
  This clause records the exact wire contract both sides implement
  (`companion/WindowsForeground/`, `BTRemote/WindowsForeground.swift`); it does **not** certify
  verification — the Swift client has never been compiled (no Xcode/swift on this Windows machine),
  so implementation claims stay CI-only per I, and physical acceptance stays outstanding
  (§9 item 10).
  The iPad requests the iOS local-network permission (`NSLocalNetworkUsageDescription`, §4) only
  when it actually pairs with or connects to the helper — never at launch and never for the plain
  §7.1 path. If the user denies that permission, the app behaves exactly as §7.1 defines (generic
  CONTROL layout); denial must not affect BLE HID pairing or any existing input path.
- **D. Executable identity.** The helper identifies the foreground application by its **executable
  identity** — the full path and file name of the process owning the foreground window. It does NOT
  identify apps by window title (titles are user- and locale-editable and are not trusted for
  identity). The iPad maps a known executable to a layout profile. Canonical mappings defined here:
  `Code.exe` → VS Code layout, `chrome.exe` → Chrome layout, `explorer.exe` → Explorer layout.
  Matching is strictly by configured executable file name/path, never by title. That mapping is
  **user data, not code**: the helper reads it from the JSON layout document described in F (the
  file it creates at `%LOCALAPPDATA%\iPadForegroundHelper\profiles.json`), and the three canonical
  mappings above are that document's shipped defaults.
- **E. Unknown / disconnected fallback.** If the foreground executable is not one of the configured
  mappings (an unknown app), or the helper is not running / not paired / the channel is down, the
  iPad must show the default generic CONTROL layout from §7.1, unchanged. Losing the helper
  connection must never break any input path and must never leave the iPad on a blank or invalid
  layout — it falls back to §7.1 immediately.
- **F. Action sets.** Each layout is an ordered set of small labelled buttons (same §7.1 B/C panel
  affordances: small icon/label buttons, touch-through pad, only one temporary surface open at a
  time; never a full keycap keyboard or a wide sidebar). Every button is bound to an existing
  keyboard / shortcut / character sequence that is sent to the focused Windows app through the
  **existing HID path** (`HIDInput` / `KeyTypist` / `keyReports(for:modifiers:)` / `sendConsumer`,
  §4 / §5). No new HID report type, no new keycode, no new input channel. The layout definition
  (which buttons, their labels, and the exact keystroke/character sequence each one sends) is
  **data / user-configurable**, so a new app profile or a different project's targets can be added
  without a code change; a layout may only reference sequences that already produce existing HID
  reports.
  Concretely, that data is **one JSON document** the user can edit without touching any source:
  `{ "profiles": [ { "id", "title", "executables": ["Some.exe"], "actions": [ { "label",
  "chord" | "sequence" | "text" | "settings" } ] } ] }`. A `chord` is one chord (`"Ctrl+Shift+P"`,
  `"F5"`), a `sequence` is an ordered list of chords (`["Ctrl+K", "Ctrl+O"]`), `text` is a literal
  string/path to type, and `settings` names the app-settings key holding the user's own chord.
  All four targets dispatch through the existing `HIDInput`/`KeyTypist` keyboard path, so no new
  keycode or report type is possible; an unconfigured or unparseable target sends nothing and its
  button stays disabled. The Windows helper reads the same document (it creates
  `%LOCALAPPDATA%\iPadForegroundHelper\profiles.json` from the shipped defaults on first run) to
  decide which executables are "known", and the iPad edits the matching copy in
  **Settings → App layouts (JSON)**, with **Restore shipped layouts** to get the shipped defaults
  back; the six project/folder targets below stay editable in their own Settings fields. The shipped
  defaults are listed verbatim below and stay unchanged.
  - **VS Code layout — required action set (verbatim, exact labels):** `New Window`, `Open Folder`,
    `Frost Pi`, `SideChatAI`, `Explorer`, `Source Control`, `New Terminal`, `Close Saved`,
    `Split Editor Right`, `Move to the editor`, `Quick Open Browser Tab`. These labels must appear
    exactly as written. `Frost Pi`, `SideChatAI`, `Quick Open Browser Tab` and any similar
    project-specific target are **user-defined targets**: each is ultimately a keystroke / shortcut /
    command sequence that the user configures (e.g. a VS Code command palette entry, a task, a
    folder path, an extension shortcut). Their concrete keystroke target must be **configurable in
    app settings**, never hard-coded, so the project can change without a code change. In the shipped
    document these six actions are `"settings"` targets, i.e. the user types the chord (or typed
    text/path) in the matching Settings field; the three VS Code targets and the three Explorer
    targets all stay user-configurable.
  - **Chrome layout — useful action set:** `New Tab` (Ctrl+T), `Close Tab` (Ctrl+W), `Reload`
    (Ctrl+R), `Focus Address Bar` (Ctrl+L), `Back` (Alt+←), `Forward` (Alt+→), `History` (Ctrl+H),
    `Show Bookmarks` (Ctrl+Shift+B), `Full Screen` (F11).
  - **Explorer layout — useful action set:** `New Window`, `New Tab` (Ctrl+T), `This PC`,
    `Documents`, `Downloads`, `Search` (Ctrl+E), `Select All` (Ctrl+A), `New Folder`
    (Ctrl+Shift+N), `Rename` (F2).
- **G. Security constraints.** Privacy-preserving by default: the helper reports an executable
  identity only when it matches a configured/known mapping; it must not exfiltrate arbitrary
  foreground executables, window titles or window contents to the device. Transport is
  localhost/LAN-only, encrypted and mutually authenticated. The helper must not auto-start into a
  state that overrides the user's §7.1 default layout without a completed pairing (clause E).
- **H. Relationship to existing scope.** This makes the previously non-goaled "Windows companion /
  WebSocket transport" and "dynamic per-app panels" items (§11, §13) **approved, specified and
  implemented in source — but not verified**: the C# helper builds and its dependency-free tests
  pass on this Windows machine, the Swift client has never been compiled (no Xcode/swift here) and
  no §7.2 behaviour has been tested on real hardware. The core product line stays exactly
  "IPAD → BLE HID → WINDOWS"; the helper sits beside that path and only selects which layout the
  iPad presents, it never carries input.
- **I. Verification / limits.** Implementation may claim CI only. Foreground-detection correctness,
  secure pairing, per-app layout correctness, the iOS local-network permission prompt (requested
  only at pairing/connect time) and the unknown/disconnected/denied-permission fallback all stay
  "implemented, physical verification pending" until the owner runs the added §9 checks with the
  helper on the real Windows PC + iPad.

## 8. Active milestone
Per the reconciled roadmap (2026-09-20/21, renumbered for §7.1/§7.2):
1. Unified CONTROL surface — UX canon (§7) + unified control contract (§7.1); this absorbs the
   former stages "TRACKPAD usability" and "DECK", which no longer exist as separate modes
2. GAME usability → 3. Direct Input / Windows keyboard semantics → 4. Gyro aim → 5. Windows
helper and foreground-aware layouts (§7.2) → 6. Native dictation RU/EN → 7. Feedback → 8.
experimental TOUCH / absolute digitizer.

Implemented: **modifier hold + combined keycaps after `0bccedc`** — contract defined in §5
(A–G, spec `d1b68d9`); implemented in `dbe36ab`, CI GREEN (run `35652625241`).
Remaining: the user's physical verification per §9.

Stage **4. Gyro aim** is implemented — contract defined in §5.1 (spec `b9caa6d`); code in
`1284aca` with fixes `28867db`/`aa4443c`; CI green run `36203590465`; merged `c89997f` via
PR #10. The owner's §9 hardware acceptance for it is still outstanding. Stage **1. Unified
CONTROL surface** is implemented — contract defined in §7.1 (spec `97d459b`); code in `fd50ae1`
(`feat(ios): add unified CONTROL workspace`); merged `482155b` via PR #17.
The next bounded active stage is **5. Windows helper and foreground-aware layouts (§7.2)** — the
companion app, secure local pairing and per-app/foreground layout contract are defined by spec
commit `fb77782` and implemented by commit `c8babce` (`feat(windows): configure foreground app
layouts [spec fb77782]`): Windows C# helper + iPad `BTRemote/WindowsForeground.swift` + the
user-editable JSON layout document from §7.2 F. Nothing in §7.2 may be called verified:
the C# helper builds and its dependency-free tests pass locally (67 checks), Swift cannot be
compiled on this Windows machine so the iOS client is unbuilt and its CI build is still pending,
and §9 item 10 stays outstanding.
Later unstarted roadmap stages (native dictation RU/EN, feedback,
experimental TOUCH / absolute digitizer) still each require their own preceding spec commit; no
dictation contract is written here.

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
  UNDO, TASK VIEW, SCREENSHOT, SEARCH, PLAY/PAUSE from the always-visible set, and TASK MGR,
  EXPLORER, DESKTOP, DESK ←/→, VOL−, MUTE, VOL+, ESC, TAB, PRTSC, ENTER, BACKSPACE, INSERT,
  DELETE, HOME, END, PGUP, UP, PGDN, LEFT, DOWN, RIGHT and F1–F12 from the temporary
  "More shortcuts" DECK panel — and each still reaches Windows;
  (d) trackpad gestures from item 4 still work in the pad's free areas while controls are present;
  (e) "Extra keys" opens the custom keyboard panel — a panel distinct from "More shortcuts", with
  its own separate entry control, and opening it closes "More shortcuts" — contains only the
  shipped custom keycaps (no embedded text field, no embedded Send/Clear), does NOT summon the iOS
  keyboard, does NOT focus the text field, and closes explicitly via its own affordance; the
  shipped custom controls must all still be present and working from it: PRTSC reaches Windows,
  SPACE types a space, and the right-side Ctrl/Alt Gr/Shift/Win modifiers hold-and-combine exactly
  like the left ones (§5 A–G);
  (f) "Text entry" is reachable on its own, independently of "Extra keys" (its own entry control,
  no mode switch, the field is not inside the custom keycap panel); opening the "Text entry"
  surface alone does not force focus and does not by itself raise the iOS keyboard; tapping the
  text-entry field DOES summon the system keyboard and typing still reaches Windows;
  (g) opening "Extra keys" while the native keyboard is up leaves exactly one surface visible;
  opening "Text entry" closes "Extra keys" and "More shortcuts"; once the field is focused it
  stays present and usable while the native iOS keyboard is visible, and live typing, Send and
  Clear all still work with that keyboard on screen;
  (h) GAME behaviour is unchanged.
- 10. Windows helper and foreground-aware layouts (§7.2) — physical checks only, on the real
  Windows PC + iPad; the helper is out-of-band signalling only and never carries or sends input:
  (a) **Pairing:** on the same LAN, start the helper on Windows and complete the one-time local
  pairing with the iPad via the helper's short pairing code / QR; the handshake succeeds, the
  long-lived secret / pinned certificate is re-used on every later connection, and any peer that
  does not present it is rejected; confirm the channel is TLS-only (no plaintext) and the helper
  binds a local/LAN interface only (never a public interface).
  (b) **Foreground app switching:** with the helper running, bring VS Code, then Chrome, then
  Explorer to the foreground on Windows; the iPad must switch its CONTROL layout to the matching
  app-specific layout (VS Code / Chrome / Explorer) automatically, with no manual mode switch and
  no mode that is not the §7.1 CONTROL surface. Verify the §7.2 F action sets render with the exact
  required VS Code labels (`New Window`, `Open Folder`, `Frost Pi`, `SideChatAI`, `Explorer`,
  `Source Control`, `New Terminal`, `Close Saved`, `Split Editor Right`, `Move to the editor`,
  `Quick Open Browser Tab`) and the useful Chrome/Explorer sets, and that tapping any of those
  buttons sends its pre-configured keystroke / shortcut / character sequence through the existing
  HID path to the focused Windows app. Confirm the project-specific targets (`Frost Pi`,
  `SideChatAI`, `Quick Open Browser Tab` and similar) are taken from the configurable layout
  document / app settings and are NOT hard-coded, so a different project's targets (and a new
  executable→layout mapping, e.g. a `Cursor.exe` profile) can be used without a code change: edit
  the helper's `%LOCALAPPDATA%\iPadForegroundHelper\profiles.json` and copy the same JSON into the
  iPad's **Settings → App layouts (JSON)**, then check the layout changes again.
  (c) **Fallback:** foreground an app that is not one of the configured mappings (unknown exe), and
  separately stop the helper / drop the channel; in both cases the iPad must show the default
  generic §7.1 CONTROL layout unchanged, and must never be left on a blank or invalid layout.
  (d) **BLE input unaffected:** with the helper paired and switching layouts, the whole §5 / §7.1
  input path must still behave exactly as in items 4–7 — mouse move/tap/scroll, keyboard typing and
  Direct Input — confirming the helper never carries, sends or overrides HID input and never
  re-negotiates BLE/HOGP pairing.
  (e) **Local-network permission:** verify the iOS local-network permission
  prompt (`NSLocalNetworkUsageDescription`, §4) appears only on the first helper pairing/connect and
  never at app launch and never on the plain §7.1 path; verify that denying it leaves the generic
  §7.1 CONTROL layout and all BLE HID pairing and existing input paths (items 4–7 / §5) completely
  unaffected.
- Ready = all mandatory items (former MVP table 1–14) plus items 9–10 work AND lock-screen
  acceptance passes.
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
  `BTRemote uses device motion to control the mouse in GAME mode.` (the motion protected-file
  exception §5.1 J allows; the separate local-network exception is defined in §4/§7.2).
- **Unified CONTROL surface (§7.1):** implemented — code `fd50ae1` (`feat(ios): add unified
  CONTROL workspace`) [spec `97d459b`], merged `482155b` via PR #17; this replaces the separate
  TRACKPAD and DECK modes (`BTRemote/KeyboardView.swift`, `BTRemote/RemoteView.swift` at
  `3a3ddf2`). Physical verification stays pending per §9.
- **Native dictation RU/EN:** not implemented (🎙 placeholder).
- **Windows helper and foreground-aware layouts (§7.2):** implemented and committed in `c8babce`,
  **not verified**.
  The C# helper builds with `dotnet build` and its dependency-free tests pass locally
  (`ALL TESTS PASSED`, 67 checks). The Swift side (`BTRemote/WindowsForeground.swift`,
  `BTRemote/KeyboardView.swift`, `BTRemote/AppSettings.swift`, `BTRemote/SettingsView.swift`) has
  never been compiled — there is no Xcode/swift on this machine — so its build must be confirmed by
  the macOS GitHub Actions job and its behaviour by the owner's §9 item 10 hardware session. Do not
  describe §7.2 as passed, and do not treat the previously hard-coded VS Code / Chrome / Explorer
  action sets or the fixed executable map as finished work: both are now the user-editable JSON
  document (§7.2 F).
- **Build:** no Xcode/swift on the Windows machine — "build passes" is verified up to code
  HEAD `aa4443c` (CI run `36203590465`; earlier code HEADs: `dbe36ab` / run `35652625241`,
  `ac87c61` / run `35642707603`, `0bccedc` / run `35511332912`, `7b8679d` / run `35561610311`);
  any newer Swift edit is unverified without a new CI run — which includes the §7.2 F work in
  `BTRemote/WindowsForeground.swift` / `KeyboardView.swift` / `AppSettings.swift` /
  `SettingsView.swift` (committed in `c8babce`, never built). The C# companion builds and its tests
  pass locally (`dotnet`, .NET 8, no NuGet).
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

**Non-goals / future work, not active:** OpenClaw, clipboard / voice / state, macros, telemetry,
accounts, cloud, process monitoring. (Windows companion / WebSocket transport and dynamic per-app
panels are no longer non-goals: they are approved and spec-defined at §7.2, pending implementation.)
Current product is exactly: IPAD → BLE HID → WINDOWS.

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
- Phase B: Windows companion / WebSocket transport (supersedes "no Windows-side software") and
  dynamic per-app / foreground-aware layouts — the contract is defined at §7.2 (spec commits
  `b751488` / `fb77782`) and the implementation is committed in `c8babce`; that implementation is
  still unverified — the Swift client has never been built and the §9 item 10 hardware checks are
  outstanding.
- OpenClaw; clipboard / voice / state integrations.
- Deferred backlog: TOUCH absolute digitizer (spec commit first; feature flag; separate branch;
  BLE-stack implications to be researched), gyro aim (implemented and CI-verified in `1284aca`
  + fixes `28867db`/`aa4443c`, CI run `36203590465`; physical acceptance pending per §5.1 L /
  §9), native dictation, modifier combined keycaps / sticky restore (specified in §5/§9;
  implemented in `ac87c61` + `dbe36ab` — physical verification pending), the remaining §7.2 items
  (CI build of the Swift client and the §9 item 10 hardware checks).
