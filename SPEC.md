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
The product has two targets: existing PC control through BLE HID, and owner-approved direct
TV control over local Wi-Fi (§7.3, specification only; wake unconfirmed).
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
  Bluetooth HID host. Basic PC input requires no Windows-side software; the optional
  foreground-layout helper is defined in §7.2 and never carries input.
- No paid Apple Developer Program: build = unsigned IPA via GitHub Actions; install via
  SideStore/Sideloadly (re-sign on device with free Apple ID).
- Additional approved target: **TCL 85C755 over Wi-Fi only**, directly from the iPad (§7.3).
- Imported upstream extras (iPhone remote UI and Bluetooth Classic backend) remain out of scope.
  The legacy HID DPad is not an implementation of the new network TV target.

## 4. Current architecture
Swift/SwiftUI app `BTRemote`; Xcode project generated via xcodegen from `project.yml` (project
not committed; Swift 6.0, strict concurrency complete; iOS deployment target 15.0).

PC input transport: **BLE HID over GATT only.** TV is a separate local-network target (§7.3);
Android TV Remote v2 is its primary candidate, not yet implemented or hardware verified. `BTRemote/LowEnergy/`: `HIDPeripheral.swift`
(CBPeripheralManager, HID service 0x1812, Report Map, Protocol Mode, Boot Keyboard I/O, report
references, `*EncryptionRequired`, bootstrap report on subscribe; `sendMouse`/`sendKeyboard`/
`sendConsumer`/`sendSystemControl`), `HIDProfile.swift` (UUIDs + 303-byte report map: the original 239 bytes plus the additive
§5.2 gamepad block),
`HIDReports.swift` (MouseReport, KeyboardReport 8 bytes, ConsumerReport, GamepadReport 7 bytes,
Keycode enum),
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
`BTRemote connects to your paired Windows PC on the local network to show app-specific controls.` (§7.2, current implementation).
For future TV implementation only, §7.3 D supersedes that exact wording and permits a narrowly
verified `NSBonjourServices` list if discovery needs it. No other key or entitlement change is
granted; everything else in those two files stays untouched. A third exception is
granted by §5.2 (Screamer racing gamepad): **additive-only** work in
`BTRemote/LowEnergy/HIDReports.swift`, `BTRemote/LowEnergy/HIDProfile.swift`,
`BTRemote/LowEnergy/HIDPeripheral.swift` and `BTRemote/HIDInput.swift` — no existing report, byte,
struct or behaviour may change there, and `BTRemote/Classic/` stays untouched unless the implementer
proves it is necessary (§5.2 D). No `Info.plist`/`entitlements.plist` change is expected for §5.2
(the motion key needed for the racing gyro is already present from §5.1 J).

## 5. IMPLEMENTED and CONTRACT-DEFINED behavior
(§5.1 code now EXISTS in current main — implemented per spec `b9caa6d` in `1284aca` with fixes
`28867db`/`aa4443c`; CI green run `36203590465`; merged `c89997f` via PR #10. The only
outstanding item for gyro aim is the owner's §9 hardware acceptance, not code. Swift compilation
was never possible locally — Windows without Xcode/swift — so build verification = CI only,
see §12.)
- **BLE pairing:** iPad auto-advertises HID on launch; Windows pairs it as a standard BT
  keyboard+mouse; connection state visible in app (`SetupView`/`NotConnectedView`).
  IMPLEMENTED + MEASURED (user confirmed basic path finger→BLE→Windows + typing on hardware).
- **BLE advertising recovery (CONTRACT DEFINED ONLY — not implemented; §9 item 11):** whenever the
  CoreBluetooth peripheral-manager state leaves `.poweredOn` and later returns to `.poweredOn`,
  and auto-advertising is still authorized (`AppSettings.autoAdvertiseKey`,
  `BTRemote/BTRemoteApp.swift`), the app must restore its HID service as needed and resume
  advertising **without requiring an app restart**. Scope is exactly this observed state-handling
  gap in `BTRemote/LowEnergy/HIDPeripheral.swift` (`peripheralManagerDidUpdateState`): it clears
  `isAdvertising` when the state leaves `.poweredOn`, but on return to `.poweredOn` it calls
  `installServices()` only when `!isHIDServiceAdded` — if that flag is still `true` from before the
  transition, nothing is re-installed and `startAdvertisingNow()` is never reached, so the app
  keeps reporting "advertising: no" and Windows simply stops seeing the device.
  This is **lifecycle recovery, not a new latency target** and not a claim that it fixes every
  disconnect cause: the HOGP profile and report map/report references (§4/§5), the
  `*EncryptionRequired` pairing and security model (§4), the existing report semantics and the
  existing low-connection-latency contract (§5 "Low connection latency", a request not a guarantee)
  all stay exactly as already specified. No maximum pairing/advertising duration is introduced here.
  Windows may still reconnect on its own schedule through its normal host behaviour — what must NOT
  be needed again is deleting and re-pairing the paired HID device.
  `BTRemote/LowEnergy/` is the protected boundary (§4): the implementation commit must follow this
  spec commit, cite a specific technical reason and get focused review.
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
  other permitted exception is `NSLocalNetworkUsageDescription` as defined in §4/§7.2
  (with the future TV wording and narrowly scoped Bonjour exception in §7.3 D).
  All authorized usage-description/Bonjour changes require focused review. `BTRemote/entitlements.plist`, `BTRemote/LowEnergy/`,
  `BTRemote/Classic/`, `BTRemote/HIDInput.swift` and `BTRemote/HIDReports.swift` stay untouched.
- **K. No artificial smoothing, filtering or latency** may be added to the input pipeline.
- **L. Verification:** implementation may claim CI only. Do not claim gyro aim works until the
  owner has run the §9 hardware acceptance including GAME gyro; until then it stays
  "implemented, physical verification pending".

### 5.2 Screamer racing gamepad — CONTRACT DEFINED AND IMPLEMENTED (CI build passed; physical acceptance pending)
Spec-first contract for the operator-requested first playable **Screamer** (racing) gamepad surface.
The contract was defined at base `1519ee6b00cd408312f610fe2b88c29b2c79e344` (`origin/main`, merge of
PR #22) by spec commit `e8a62aa`, which changed `SPEC.md` only. The contract is now implemented in
source by `8e9cc6b` (`feat(game): implement Screamer racing gamepad [spec e8a62aa]`) and the follow-up
fixes `bfb3231` (`fix(game): iterate gamepad subscriber set [spec e8a62aa]`) and `4fa3506`
(`fix(game): hide racing controls outside racing [spec e8a62aa]`), all of which reference
this spec SHA as required by the rule at the top of this file. `GamepadReport`, Report ID 7, the
additive gamepad bytes in the report map and the racing UI therefore do exist in code, and that code
is now **CI-built**: workflow_dispatch run `36372951698` passed Test → Build → Package → Upload on
implementation HEAD `6c746a6f14a25c08063694b21796f667471a7602`, and push run `36373205510` passed the
same jobs on merge commit `30ccaaa3be6f902a4eb91f7954f322d508f830c6` (PR #23). The unsigned
`BTRemote.ipa` artifact from that build is available in the workflow artifacts.
Historical, superseded: the earlier run `36371784190` at `8e9cc6b` completed **FAILED** in the app
build step (`Set<UUID>.keys` — `gamepadSubscribedCentrals` is a `Set`, not a dictionary); its Test
step passed, and `bfb3231`/`4fa3506` corrected that build error.
CI build is not functional verification. The §9 item 12 hardware acceptance — including the Windows
descriptor-cache remove/re-pair action (§5.2 M) and the physical Screamer test — is still outstanding,
so nothing in this section may be described as working on hardware yet.
**Source implemented, CI and physical verification outstanding:** §5.2 H has been re-specified
(steering = signed rotation about the device screen-normal, see H) and that mapping is now
implemented in source by `7be857e` (`fix(game): restore wheel steering and recenter [spec 9adfd9d]`,
branch `fix/racing-wheel-steering`), which follows spec commit `9adfd9d` as required by the rule at
the top of this file. The dependency-free regression tests required by §5.2 N are added in
`BTRemoteTests/GamepadTests.swift` and call that same production seam
(`RacingMapper.screenNormalDegrees`, `RacingSourceState.recenterSteering()` in
`BTRemote/GyroAim.swift`). The CI evidence recorded above belongs to the pre-wheel-fix code:
neither `7be857e` nor those tests has been compiled or run on this Windows host (no Xcode/swift,
§12) and no CI run has built them yet, so the wheel steering/recenter work stays
"implemented in source, CI and physical verification pending".
- **A. Why the protected HID exception is technically necessary.** Screamer needs **analog**
  steering plus **analog** gas/brake plus separate action buttons, usable at the same time. The
  existing HID surface cannot express that: `MouseReport` (`BTRemote/LowEnergy/HIDReports.swift`)
  carries **relative** `dX`/`dY`/`wheel` byte deltas — "move by N counts", not "the stick is at
  position P" — and one report describes exactly one device, so a stick position, a trigger value
  and a button cannot be asserted concurrently. A relative mouse report therefore cannot encode
  analog current-state axes, and a keyboard-keycode workaround (WASD/E/Q) is digital-only and would
  collide with the shipped keyboard/"Extra keys" panels. The only correct fix is a **standard HID
  gamepad report** (Usage Page Generic Desktop, Usage Game Pad `0x04`) so Windows enumerates the
  iPad through its built-in HID game driver: no new dependency, no Windows-side software required
  for the gamepad, no private iOS API, no second transport, no Game-Controller/MFi route.
- **B. Report ID (chosen from real code, not assumed).** Inspect `BTRemote/LowEnergy/HIDProfile.swift`
  (`enum ReportID`) before choosing. Verified at base `1519ee6`: `mouse = 1`, `keyboard = 2`,
  `keyboardLEDs = 3`, `battery = 4`, `systemControl = 5`, `consumerControl = 6` — all taken. The
  gamepad therefore takes the next unused **Report ID 7**. No existing report ID, report map byte,
  struct or report semantics may change; the gamepad report is strictly additive and every existing
  mouse/keyboard/keyboard-LED/battery/system-control/consumer report stays byte-identical.
- **C. Report shape (static map, fixed length, signed and clamped fields).** Exactly one
  fixed-length input report carries the whole controller state at once, so one BLE notification can
  express stick + triggers + buttons together. Plan of record, fields in this order: `buttons`
  bitmap (bit0 = A, bit1 = B, bit2 = X — **at least three** independent ability bits; bit3–bit7
  reserved, always sent 0); `lx` signed (left-stick X, from gyro); `ly` signed (left-stick Y,
  unused, stays neutral 0); `rx` signed (right-stick X, from the floating drag); `ry` signed
  (right-stick Y, unused, stays neutral 0); `lt` unsigned (brake); `rt` unsigned (gas).
  **There is no leading Report ID byte in the payload.** Verified in the existing code at `1519ee6`:
  every HOGP path sends the bare report payload on its own Report characteristic
  (`HIDPeripheral.swift:129,135,139` `broadcast(report.data, reportID: ...)`, `makeReportChar(_:,type:)`
  at `HIDPeripheral.swift:354`, plain field `Data` in `BTRemote/LowEnergy/HIDReports.swift`), and the
  Report ID is carried by that characteristic's **Report Reference descriptor**
  (`HIDProfile.reportReference` 0x2908, value `id.descriptor(type)` = `[reportID, reportType]`), not
  prepended to the value bytes. The gamepad must follow that same pattern: a dedicated Report
  characteristic (0x2A4D) whose Report Reference descriptor is `[7, 1]`, and `GamepadReport.data` is
  exactly the fixed-length field payload with **no ID prefix byte**.
  Do not conflate two different sizes: the **report map** declares each field's bit length
  (`Report Size` × `Report Count`), while the **characteristic value** carries whole bytes of
  `GamepadReport.data`. With the field widths above (1 byte buttons + 4 signed axis bytes + 2
  unsigned trigger bytes) the payload is exactly **7 bytes** and byte-aligned.
  Fields must use **standard Generic Desktop usages**, and the right stick must not be conflated with
  `Rz`: recommended arrangement is `lx` = X (0x30), `ly` = Y (0x31), `rx` = Rx (0x33), `ry` = Ry
  (0x34) — one standard axis pair per stick — with `lt` = Z (0x32) and `rt` = Rz (0x35) as the two
  analog trigger axes; buttons stay Usage Page Button (0x09 0x01 / 0x02 / 0x03, one bit each). This
  arrangement is the recommended starting point, not an assumption: the implementation commit must
  justify the final usage assignment against the **actual Windows mapping** observed on the real
  device (which axes Windows/Screamer bind for the gamepad) and may re-order the fields there, as long
  as each field keeps its own distinct standard usage and the four axes plus two triggers stay
  independently addressable.
  The report map block stays a **static, append-only** section of `HIDProfile.reportMapData` (the
  existing 239 bytes stay unchanged) and the report must be a fixed-length, byte-aligned structure
  that always fits one ATT notification. All axis fields are **signed** and every value must be
  clamped to its field range before it is sent (same discipline as `HIDInput.clamp`,
  `BTRemote/HIDInput.swift:67`).
- **D. Protected-boundary exception (minimal, additive only).** This spec commit authorizes exactly
  this protected-path work, and nothing more: add a `GamepadReport` struct (+ its `ReportID`
  case) to `BTRemote/LowEnergy/HIDReports.swift`; append the additive gamepad block to
  `HIDProfile.reportMapData` and extend `enum ReportID` in `BTRemote/LowEnergy/HIDProfile.swift`;
  add the gamepad report characteristic, `sendGamepad(...)` and its cache entry in
  `BTRemote/LowEnergy/HIDPeripheral.swift`; add the matching `sendGamepad` plumbing in
  `BTRemote/HIDInput.swift`; add the racing input source and its on-screen controls
  (`BTRemote/GyroAim.swift` `GameInputMode`, `BTRemote/KeyboardView.swift` temporary GAME chrome).
  §5.1 J stays fully in force: the existing gyro-aim code, the existing report structs, the existing
  report-map bytes and the existing mouse/keyboard/consumer/Direct-Input paths must not change.
  Where §5.1 J says those files stay untouched, that stays true for everything already in them; the
  additive additions listed above are the only exception and only for this contract.
  `BTRemote/Classic/` is not to be modified unless a later finding **proves** the gamepad cannot
  work over the BLE path without it — that would need its own preceding spec change. No new
  third-party dependency and no external/private-API route.
- **E. Gamepad backpressure = current state, latest state wins.** The existing mouse path
  *accumulates* deltas (`pendingMouseDX/DY/Wheel`, `HIDPeripheral.swift:52,117`) because mouse
  reports are relative; that model must not be reused for the gamepad, because replaying queued
  absolute stick positions would move Windows backwards. The gamepad must therefore keep a **single
  latest-wins current state**: the app holds one current `GamepadReport`; if a send is not accepted
  (`updateValue(...)` returns false / `isReadyToSendNotification == false`), do not enqueue a second
  copy and do not reuse the `pendingMouse*` accumulators — keep that one newest state pending and
  re-send it when `peripheralManagerIsReadyToUpdateSubscribers` fires, so Windows always converges
  on the newest state. No smoothing, filtering, interpolation, cadence coupling, artificial delay or
  other latency may be added to this path (same rule as §5.1 K).
- **F. Required integration points (all of them).** Implementation must wire the new report through
  the existing lifecycle instead of adding a parallel path: `installServices()` /
  `buildHIDService(...)` must create the gamepad characteristic with `makeReportChar(.gamepad,
  type: .input)` and register it in `charsByReportID`; `peripheralManager(_:didReceiveRead:)` /
  `readValue(forRequest:)` must answer a read of that characteristic with the current cached
  gamepad report; `sendGamepad` must go through the existing `broadcast(_:reportID:)` /
  `updateValue(...)` notify path; `cachedReports` (`HIDPeripheral.swift:44`) must be seeded with the
  **neutral** gamepad report (axes 0, triggers 0, all bits released) alongside the existing four
  entries, so a host reading before the first send reads neutral; and `_resetForRestart()` plus the
  §5 "BLE advertising recovery" flow (PR #22: spec `4370704`, commits `8a82419`/`d651414`) must keep
  working exactly as specified — which is precisely why the gamepad report has to be created inside
  `installServices()` and not once at launch.
- **G. Racing mode is nested under GAME (no new top-level mode).** The top bar stays
  `GAME | CONTROL | TOUCH` for the PC target; nothing may add a fourth PC mode. The separate
  PC/TV target selector is defined in §7.3 and does not change this PC mode contract. Inside the temporary GAME
  chrome the input-source picker gains a nested **`RACING`** choice (`GameInputMode.racing`) next to
  the existing `touch | gyro | hybrid`; those three (the AIM / gyro-aim path of §5.1) keep their
  behaviour, labels, sensitivity defaults, persistence and unavailable-status handling exactly as
  implemented, and RACING must not be achieved by changing them. Default selected source stays
  `touch` on first launch, and any already-persisted `gameInputMode` value must still resolve
  (upgrade rule as in §7.1 A).
- **H. Steering = signed rotation about the device screen-normal, RECENTER → LX.** RACING steering
  must not reuse the §5.1 incremental-delta output: it is an **absolute** axis deflection computed
  from the device attitude **relative to the baseline established by RECENTER**, written into the
  gamepad's left-stick X field.
  The rotation steering must follow is the **signed rotation about the device screen-normal (Z)
  axis** — the motion of turning a steering wheel while facing the screen — **not** the rotation
  about the device X axis that the §5.1 aim path uses for horizontal mouse movement. A **clockwise**
  turn as the user faces the screen means **positive** left-stick X; the opposite turn means
  negative. Because that axis is the device's own screen normal, the mapping must not depend on how
  the device is held, so landscape left and right stay symmetric.
  On RACING activation, on app reactivation, on returning to GAME and on pressing RECENTRE, the
  current attitude becomes the baseline and no movement is emitted; turning the iPad back to the
  recorded pose must return the stick to centre (0), never a drifted position.
  Reuse the existing single device-motion pipeline (`GyroAimController` / `CMMotionManager`,
  `.xArbitraryZVertical`) — no second motion manager and no new dependency. Initial tuning (the
  operator-requested starting values for the first playable build, to be corrected on hardware, not
  final): **deadzone ≈2°** of rotation from the baseline → axis stays 0; **full lock ≈30–35°**
  (start at 32°) → full-scale deflection; **expo ≈1.3–1.5** (start at 1.4).
  **Reason for re-specifying:** the shipped racing code derives steering from the device-X rotation
  component, which is not the motion a steering wheel uses, and the owner explicitly asks for normal
  steering-wheel rotation. The owner's one hardware session only established which inputs did not
  respond (gyro steering, gas, brake and the free drag did not; BOOST/ABILITY1/ABILITY2 did); that
  is an observation, **not** proof of a root cause, and gas/brake/drag are not addressed by this
  section. Which quaternion component, sign and byte width implement the semantic above is one
  implementation choice to be written and justified in the implementation commit, not specified
  here; the binding requirement is the semantic — signed screen-normal rotation from the recentered
  baseline → signed left-stick X, clockwise positive. The §5.1 aim path and its mouse sensitivity
  stay exactly as already implemented and racing never reuses them.
  Two further requirements in that same seam: (1) pressing RECENTRE must not only move the baseline
  — it must immediately clear a steering deflection that was already transmitted, by sending LX = 0
  while preserving every other held field (both pedals, the floating drag, the ability buttons);
  (2) a sample whose rotation from the baseline is exactly zero must still be mapped (to a centred
  stick), so a device returned exactly to the recorded pose cannot leave a nonzero racing LX
  latched. If device motion is unavailable, produce no steering input and show the existing
  "unavailable" chrome (§5.1 H); never fall back to keycodes for steering. The clockwise-positive
  sign is the owner-requested behaviour and still needs the §9 item 12 physical confirmation.
- **I. Floating touch = independent raw UIKit drag → RX.** RACING keeps an **independent, floating**
  raw-UIKit touch area that covers **nearly all of the remaining free racing surface** — every part
  of the GAME surface that is not a racing button/trigger hit region and not the §7.1 CONTROL
  trackpad — and is therefore **not** restricted to a right-side region only (same high-fidelity
  handling as §5 "GAME high-fidelity input": `touchesBegan`/`touchesMoved(_:with:)` with
  `UIEvent.coalescedTouches(for:)`, predicted touches not used). It is not the §7.1 CONTROL trackpad
  and not the left/gyro area, so a thumb drag can drive the second stick at the same time as
  steering, gas/brake and buttons. Each touch's own `touchesBegan` point is its **origin** (the
  surface floats, there is no drawn pad to aim at); displacement from that origin is scaled by the
  initial tuning — **deadzone ≈8 pt**, **full travel ≈100 pt** (requested 80–150 pt class) →
  full-scale right-stick X — into the gamepad's right-stick X field; on `touchesEnded` or
  `touchesCancelled` that field returns to 0 immediately.
  Hit-region ownership: a touch that **begins** inside a button/trigger hit region belongs to that
  control for its whole life and must never drive RX, even if the finger later slides across the
  racing surface; a touch that begins on the free racing surface keeps driving RX even if it later
  slides over a button/trigger region. The racing surface must not intercept any §7.1 CONTROL
  gesture, §5 keyboard or Direct-Input touch (control hit areas are disjoint from the pad and from
  each other; only actual hit areas may intercept, §7.1 D).
- **J. Racing controls: LT = brake, RT = gas, ≥3 ability buttons.** Gas is the **RT** field, brake
  is the **LT** field (two separate on-screen controls on the racing surface, two separate fields of
  the same report, so both can be present at once and each releases independently). At least
  **three** independent ability button bits must exist (initial assignment A, B, X) and each must be
  assertable simultaneously with the others, with either trigger and with the steering axes in one
  report. All racing buttons are momentary: pressed = bit set, released = bit cleared, and the
  release report must be sent even when the earlier press was never acknowledged by the host
  (latest-state-wins, E).
- **K. Out of scope: no remapping, no settings, no layout work.** No user-configurable button/axis
  remapping, no per-game or per-app layout work, no new Settings fields, no use of the §7.2 JSON
  layout document for gamepad actions, no new input channel, no dictation or Touch-digitizer work.
  The tuning values in H and I are compile-time defaults for the first playable build. Nothing
  already shipped (§5, §7, §7.1, §7.2 — CONTROL pad, Text entry, Extra keys, More shortcuts, Windows
  helper) may be removed, relabelled or moved to make room for RACING.
- **L. Neutralization lifecycle (every case must be handled).** Windows must never be left with a
  stuck axis, trigger or button. A full **neutral** gamepad report (axes 0, triggers 0, all bits
  released, cached as neutral too) must be sent whenever: RACING is deselected in the GAME chrome
  (back to Touch/Gyro/Hybrid); the mode leaves GAME (to CONTROL or TOUCH); the app resigns active,
  is backgrounded or suspended; the floating drag ends or is cancelled (I); any ability button or
  trigger is released; BLE disconnects, the central unsubscribes, or Bluetooth leaves `.poweredOn`
  and later returns (restart/re-install path, F); or device motion becomes unavailable (H). When
  several sources are held at once, releasing one must not clear another's still-held state, and
  the clearing report must be the newest state (E).
- **M. Windows descriptor cache / re-pair fallback.** Adding a report changes the byte length and
  content of the HID report map, and a Windows host that already paired the device may keep the old
  cached descriptor and not show the new gamepad. Documented fallback for the implementation and for
  §9: if Windows does not enumerate the gamepad after the update, remove the paired BTRemote HID
  device in Windows Bluetooth settings and pair it again. That is a consequence of changing a HID
  descriptor, **not** a regression of §5 "BLE advertising recovery": after the report is installed
  the app must still recover from a Bluetooth power cycle without a restart and without a re-pair.
- **N. Tests and claim boundaries.** Implementation adds dependency-free coverage for the byte-exact
  gamepad encoding (field order, widths, signedness, clamping at full scale) and for latest-state-wins
  backpressure (a second state produced before the notification is acknowledged replaces the pending
  one; no duplicated, queued or replayed gamepad reports). Swift cannot be compiled on this Windows
  machine (no Xcode/swift, §12), so implementation may claim **CI build only** — which it now has
  (runs `36372951698` / `36373205510`). It must not claim that Screamer recognises the device, that
  steering / gas / brake / ability buttons behave, or any latency or feel result. Until the owner
  completes the new §9 item 12 hardware session, this stays "implemented in source, CI-built, physical
  verification pending". No PR text may assert gamepad functionality as verified.
  The steering change in H **required** deterministic quaternion-level coverage in the same
  dependency-free harness, written against the actual production mapping; that arithmetic now lives
  in the pure, dependency-free `BTRemote/GyroAim.swift` (`RacingMapper.screenNormalDegrees`,
  `RacingSourceState.recenterSteering()`) which the harness compiles without UIKit/CoreMotion, and
  the tests are now written in `BTRemoteTests/GamepadTests.swift` against that production code.
  Required cases: clockwise and counterclockwise
  rotation about the device screen normal, a neutral and a held starting orientation, an exact
  return to the recorded baseline, q/-q equivalent orientations, RECENTER clearing LX while the held
  pedals and ability buttons are preserved, and a pure device-X (somersault) rotation not producing
  steering — every one of those cases is now covered by a check in that harness. Swift still cannot be
  compiled on this Windows machine (§12), so those tests have not been compiled or run locally: they
  are to be compiled and run by CI, and they prove the mapping only — not what Windows or Steam does
  with the reported axes.

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
section that assume separate TRACKPAD / DECK top-level modes; nothing else in §7 is weakened.
This section describes the PC target; the separate TV surface/target selector is defined in §7.3.)
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

## 7.2 Windows helper and foreground-aware layouts — CONTRACT DEFINED; IMPLEMENTED IN `c8babce` (CI build passed; physical acceptance pending)
Spec-first contract for the owner-approved optional Windows helper that tells the iPad which
application is in the foreground so the iPad can present an app-specific CONTROL layout. This is
the previously non-goaled "Windows companion / WebSocket transport" and "dynamic per-app panels"
work (§11, §13), now approved and specified. Defined at base `482155b`; no Swift, README or other
file was changed by that spec commit. The implementation is committed in `c8babce`
(`feat(windows): configure foreground app layouts [spec fb77782]`): the §7.2 F configurability gap
found by the independent review is closed — the executable→layout map and every
layout's labelled actions are one user-editable JSON document instead of hard-coded Swift action
sets, and the Swift 6 strict-concurrency problem in `AppLayouts` is gone. The code being committed
does not mean it is verified: the Swift client has never been built locally and is CI-built by runs
`36372951698` / `36373205510`; no hardware test has been run (§7.2 I, §9 item 10).

Core principle: **the BLE HID input path (§1/§3/§4/§5) is retained and is the only PC input channel.**
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
  the optional port argument), and refuses to start when no such interface exists; it must
  never listen on a public/Internet-facing, wildcard (`0.0.0.0` / `::`) or tunnel address.
  On a multihomed Windows host the operator may name the address explicitly:
  `WindowsForeground [--bind-ip <IPv4>] [port]`. `--bind-ip` is optional and the automatic
  first-eligible-interface selection above is unchanged when it is absent; the optional port
  keeps its existing meaning and default **8443**. When `--bind-ip` is given the helper binds
  exactly that address and nothing else, and only if it is a valid IPv4 private/local unicast
  address owned by an operational non-tunnel interface on this host. Invalid syntax, a public,
  wildcard or IPv6 address, or an address not assigned to such an interface, is a startup error:
  the helper prints usage and does not start. Explicit selection is **fail-closed** — it never
  silently falls back to another address. In both cases the helper still binds one concrete
  address only, never a wildcard or public address, and that bound address is the one the user
  enters in the iPad's **Windows helper** settings (§C); pairing, TLS pinning and the wire
  exchange in C are unchanged.
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
  verification — the Swift client has never been compiled locally (no Xcode/swift on this Windows
  machine); CI compiles it successfully in runs `36372951698` / `36373205510`, so compilation is
  CI-evidenced only: behaviour remains unverified and physical acceptance stays outstanding
  (§9 item 10).
  The iPad requests the iOS local-network permission (`NSLocalNetworkUsageDescription`, §4) only
  when it actually pairs with or connects to the helper — never at launch and never for the plain
  §7.1 PC path. An explicit TV connection/discovery action may also request the same permission
  under §7.3 D; helper activity must not change the selected target. If the user denies that permission, the app behaves exactly as §7.1 defines (generic
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
  pass on this Windows machine, the Swift client has never been compiled locally (no Xcode/swift
  here; CI builds it in runs `36372951698` / `36373205510`) and no §7.2 behaviour has been tested on
  real hardware. The core product line stays exactly "IPAD → BLE HID → WINDOWS"; the helper sits
  beside that path and only selects which layout the
  iPad presents, it never carries input.
- **I. Verification / limits.** Implementation may claim CI only. Foreground-detection correctness,
  secure pairing, per-app layout correctness, the iOS local-network permission prompt (requested
  only at pairing/connect time) and the unknown/disconnected/denied-permission fallback all stay
  "implemented, physical verification pending" until the owner runs the added §9 checks with the
  helper on the real Windows PC + iPad.

## 7.3 Direct TV target — base remote implemented; app library expansion approved; wake UNCONFIRMED

Owner-approved expansion: the existing app gains a **TV** target alongside **PC**.
Target hardware is **iPad Air 11-inch M2 (2024) + TCL 85C755, Wi-Fi only**. The owner
reports that the native TCL app currently does not wake this TV; that observation does
not establish the cause or prove that every direct network wake method is impossible.
The base remote is implemented at `849f530` (unsigned CI `37156028887`: 107 gamepad
and 76 TV checks). Physical pairing/control/standby/wake is not yet verified. The owner
approved the app-library/bookmark expansion below on 2026-10-04 while testing that IPA.

### A. Scope and preserved PC behavior
- The iPad talks directly to the TV on the local network. No always-on PC, Windows
  helper, cloud relay/account, custom TV APK, root or mandatory ADB/developer mode.
  The TV's existing Android TV Remote Service is an on-device prerequisite to verify.
- PC input stays on the existing Bluetooth/HID path; the optional §7.2 helper remains
  foreground-layout signalling only. Preserve PC pairing, report map/security, input
  behavior, settings and GAME/RACING/CONTROL/Direct Input; do not re-pair Windows for TV.
- Imported `DPadView.swift` sends HID consumer reports: its presence is not a TV network
  transport. Do not route the new TV controls through that HID implementation.
- iPhone UI, Bluetooth Classic, superlatency and §11 non-goals remain outside this task.

### B. Transport evidence and implementation decisions
**Android TV Remote v2 is the primary candidate, not an implemented or certified choice.**
Sources inspected 2026-10-03:
- [Google TV Help — iPhone & iPad remote](https://support.google.com/googletv/answer/11136134?hl=en&co=GENIE.Platform%3DiOS)
  documents selection of a TV, a code displayed on the TV, pairing, playback, volume,
  text entry and on/off. This is an official app capability description, not a public
  Remote v2 wire specification or a guarantee for this TCL's Wi-Fi standby.
- [androidtvremote2 author's README](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/README.md)
  identifies v2 as the protocol used by Google TV and requires Android TV Remote Service,
  without ADB/developer tools. This is primary implementation evidence, not a Google
  support contract. At that inspected revision, [client connection source](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/androidtv_remote.py)
  uses TLS and client certificate/private-key material, with default remote port 6466
  and pairing port 6467; actual service availability must be checked on the TCL.
  [Pairing source](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/pairing.py),
  [remote source](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/remote.py)
  and [message definitions](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/remotemessage.proto)
  show key commands, negotiated features and IME text messages with field/session
  counters. Available key codes do not prove that each app/firmware honors them.
- [Google's pairing protocol source](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/+/refs/heads/master/)
  is a pairing reference; do not treat it as the complete current v2 remote protocol.

Future implementation must justify a small Swift/iPadOS-compatible solution against
these sources and the real service; choose dependencies only with concrete need and
AGPL-compatible licensing. Do not invent handshake bytes, discovery service names,
feature masks or undocumented wake behavior. Manual TV address entry is an acceptable
first connection path; discovery is optional and must survive address/network changes.
Persist the paired client identity in Keychain, separate from Windows-helper credentials.
Associate it with the selected TV and verify peer identity using a pairing-bound trust
strategy; do not copy the reference client's disabled server verification as blanket
trust. Changed/revoked credentials or TV identity require an explicit re-pair flow.
Provide forget/re-pair; do not silently destroy an existing Windows or TV pairing.

### C. Target selection, controls and routing
- A compact, clearly labelled **PC / TV** selector stays reachable; show the active
  target/device. The PC mode picker remains `GAME | CONTROL | TOUCH`, with RACING nested
  under GAME. TV is a target, not a fourth PC mode; PC defaults and saved modes migrate
  without losing unrelated settings. A TV install must work with no PC connection.
- TV presents a large directional navigation area with OK, plus Back, Home, volume
  down/up, Mute, Play/Pause, power and a reachable text-entry surface. Keep controls
  usable in portrait and landscape without a permanent keyboard covering navigation.
- TV actions, repeated keys and text go only to the selected TV transport. No Windows
  HID consumer/keyboard fallback on TV failure; physical Direct Input must not leak
  into Windows while TV is selected. Windows-helper layout events cannot select PC.
- Before changing target, stop repeats, gyro/racing, typing queues and Direct Input;
  clear held modifiers/buttons, mouse buttons and gamepad state and release the old
  target while its link is available. Bind callbacks/queued work to the target/session
  that created them and discard stale work. If a link is gone, clear local/pending state
  and start the next session neutral; never replay old presses/power/text on reconnect.
- Release/cancel held TV keys on touch end/cancel, target change, loss of connection,
  view exit and app inactivity; reactivation must not resume a held/repeating key.
  Send text only into a supported, active TV input field with the correct IME session;
  show unavailable state when unsupported. Preserve Unicode text and do not promise
  universal text injection, password-field support or clipboard synchronization.
- Separate connection state from observed power state. Present unpaired, pairing,
  connecting, connected, reconnecting, local-network access denied and unavailable/error
  states with a useful retry/settings/re-pair action. Lost reachability means **power
  unknown**, not off. Bound reconnect attempts; retry after network return, foreground
  return or TV power-on without repeatedly asking for a pairing code when still valid.
  Label a power request as pending until observed; never display wake success on send.

### D. iPadOS permissions, secrets and unsigned deployment
- Preserve unsigned IPA → SideStore/Sideloadly with a free Apple ID (§3/§12). A desktop
  probe, unsigned build or simulator result cannot prove network/signing behavior on iPad.
- [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
  requires local-network permission for outgoing local TCP/UDP and Bonjour. Ask on an
  explicit TV connection/discovery action, not launch or plain PC BLE use; §7.2 helper
  connection may also trigger that shared permission. Denial must leave PC HID usable.
- This spec grants only these future `Info.plist` exceptions: replace the existing
  `NSLocalNetworkUsageDescription` with exactly `BTRemote connects to your paired Windows PC for app-specific controls and to your paired TV for remote control on the local network.`;
  add `NSBonjourServices` only for specific service types verified as used by the chosen
  discovery path. §4 protection, Bluetooth/motion keys and existing background modes
  remain; no code/plist/entitlement edit is made in this documentation stage.
- Apple distinguishes ordinary browsing of declared Bonjour service types from raw
  multicast/broadcast: the latter requires `com.apple.developer.networking.multicast`.
  Do not require WOL-broadcast or add that entitlement by assumption. First verify
  provisioning and actual re-signing/install support; a signing/entitlement change
  needs a separate concrete spec authorization before implementation. Bonjour is
  optional; a verified unicast/manual-address path can avoid that requirement.
- Store client keys/certificates and any pairing-bound TV trust material in Keychain;
  ordinary non-secret device labels/addresses may use app settings. Do not log or commit
  pairing secrets, private keys, credentials, typed TV text or SideStore material.
  Verify pairing reuse after process restart and the actual re-sign/update path; do not
  assume credentials survive uninstall or a changed signing/access-group identity.
- [Apple background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
  does not provide an always-running LAN remote. Treat control/wake as foreground actions,
  release inputs on inactivity and reconnect on return. Existing Bluetooth background
  declarations do not authorize persistent Wi-Fi keepalive or wake from a suspended app.

### E. First implementation gate: pairing → control → standby → wake from iPad
**Run this bounded feasibility chain before building out the TV UI. Wake is the key
scenario and is currently UNCONFIRMED; no part of this hardware procedure has been run.**
1. Record exact TV model/region, firmware, Remote Service version, iPadOS, installed app
   build/signing method and the Wi-Fi setup. The TV stays Wi-Fi-only; verify both devices
   are on a LAN that permits direct peer access. Inspect and record current TV settings.
2. The [TCL C755-series manual linked from 85C755 support](https://www.tcl.com/au/en/support-tv/model/85c755)
   ([PDF](https://aws-obg-image-lb-4.tcl.com/content/dam/brandsite/region/australia/AU_Mediacenter/download/C755-Series_User-Manual.pdf),
   pp. 13 and 15) describes **Settings → Network and internet → Network Standby**, and
   **Settings → System → Power and Energy → Quick start**. Network wake requires both on,
   Google TV mode, the same wireless network and a controller app supporting wake.
   The manual says long-press power + confirmed shutdown disables this feature; Quick
   start increases standby consumption. Verify actual labels/options on this region's
   firmware; record any approved changes. The manual does not specify a v2 wake packet.
3. On the **installed iPad app**, pair using the TV-displayed code; verify navigation,
   OK/Back and a volume change. Restart the app and reconnect using saved pairing.
   Proceed to standby through the normal remote action; keep mains power connected.
4. With the PC/helper off and no cloud relay, background the app and return to it to
   request wake. Observe and time the TV screen actually becoming active and confirm
   navigation works afterwards. Record transport/service reachability independently.
   Repeat the standby/wake cycle, including **at least 30 minutes in standby** before
   reopening the app and waking from iPad. No physical remote may supply the successful
   wake; it may restore the TV after a recorded failed attempt.
5. Repeat after a Wi-Fi loss/return and a normal TV power cycle; saved pairing should be
   reused when valid. Test permission denial/recovery and IP change separately from
   standby. Full shutdown/unplugging is a separate negative/control case, not standby.

Remote v2 power is a candidate only while the required service/network path can deliver
it. If Wi-Fi/service sleeps, record the failure and investigate a supported direct
alternative within scope before expanding UI work. Do not infer off from a timeout,
claim success from a sent key, or treat standby as loss of mains power. No Bluetooth
wake or mandatory broadcast-WOL promise; any alternative needs source, iPadOS signing
feasibility and real TCL proof. If the 30-minute wake gate fails, report a blocker:
powered-on control alone does not make this TV product ready.

### F. Readiness and separate hardware acceptance
- Implementation readiness: routing/session isolation and release behavior verified;
  meaningful tests for target switch, stale queued commands, reconnect and credential
  errors; actual CI build of the implementation HEAD and installable unsigned IPA.
  These checks cannot certify wake, supported IME fields or TCL key handling.
- Hardware readiness: E passes on this iPad/TCL over Wi-Fi, including repeated 30-minute
  standby wake with PC off; all C controls and representative supported Unicode text
  fields work; pairing survives restart/update as supported; reconnect and permission
  recovery behave; portrait/landscape work. Record observed results and limitations.
- With Windows paired concurrently, prove TV actions/text/Direct Input produce no
  unintended Windows input, and PC↔TV switching while keys, mouse buttons or racing
  controls are held leaves neither target stuck. Re-run the existing §9 PC regression
  spot checks for mouse, typing/modifiers, Direct Input, CONTROL, GAME/RACING and BLE
  recovery, plus helper fallback. Remaining pre-existing hardware gates stay pending.
- **Current status:** base TV implementation/unsigned build at `849f530`, CI
  `37156028887`; downloaded arm64 IPA verified. No physical pairing/control/standby/wake
  evidence is recorded. Wake: **UNCONFIRMED**. Full TV readiness still requires E/F.

### G. App library, bookmarks and direct actions — owner-approved expansion
- TV opens into a useful library with **Apps / Bookmarks / Remote** surfaces, separate
  from the unchanged PC mode picker. App/bookmark tiles launch with one explicit tap;
  the navigation remote remains available for in-app interaction. Both orientations work.
- Users can add, edit, delete, favorite and reorder their TV apps and bookmarks. App
  targets accept an Android package ID or a supported deep link; bookmarks retain a
  user-defined title and a content/site/playlist URL. A small editable catalog is a
  starting point, not a discovered list of installed TV apps. The protocol does not
  provide a verified generic installed-app enumeration: do not fabricate that list.
- Use the existing Remote v2 negotiated **APP_LINK (512)** feature and
  `RemoteMessage.remote_app_link_launch_request` **field 90**, with `app_link` field 1
  inside it. Preserve the original key/IME/power features and request APP_LINK additively.
  Reference: [pinned proto](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/remotemessage.proto),
  [pinned sender](https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/remote.py)
  and [author's package-launch implementation](https://github.com/tronikos/androidtvremote2/commit/c5d7292e8efe6201854884d8402572398ee11c2a).
  Bare package IDs are converted to `market://launch?id=<package>` as in that reference.
  This compatibility path and each app's deep-link handling require TCL verification;
  a launch may fail or open a store page. Users can replace the target with an app-supported
  deep link. Do not promise universal app/content/browser launch or silent installation.
- Provide an explicit **Open link on TV** action (typed or explicitly pasted URL),
  save-as-bookmark, and a YouTube search shortcut using a URL-encoded query. These use
  the selected TV transport; never open the target in an iPad browser as a fallback.
  Show actionable unavailable/unsupported states and the difference between a sent
  command and an observed current app. Do not claim a bookmark loaded from transport ACK.
- Show the current TV app only when supplied by Remote v2 `remote_ime_key_inject`
  app-info/package metadata; otherwise unknown. Clear it on loss/target/session change.
  Offer media previous/next, rewind/fast-forward and stop with key codes from the pinned
  proto, without asserting that every app honors them. Do not infer field activity or
  authorize text from the current-app label alone.
- Recent commands retain at most ten existing library item IDs after an explicit send;
  they are never replayed on reconnect, foreground return or app launch. Removing an
  item removes its recent entries. Bound and validate labels, package IDs, URI schemes,
  target length and library size before persistence or sending. Reject local files,
  executable/script URI schemes and malformed targets, without logging submitted URLs.
- Keep user library targets (URLs can contain credentials) in a separate TV-only
  Keychain record. No library URLs, pairing material or typed search text in logs/commits.
  Default catalog values contain no secrets. Persistence errors preserve existing user
  data and surface a useful error; do not silently replace it with defaults. Editing,
  pasting and app launch remain explicit foreground actions. No new dependencies,
  signing/multicast/Bonjour entitlements, PC helper requirements or BLE changes.
- Acceptance for this expansion: actual production encoder fixture for field90 and
  feature negotiation; unsupported/disconnected/stale-session launch rejection; URI
  and package conversion including Unicode/escaping; library CRUD/order/favorite/recent
  and serialization/error cases; current-app invalidation independent of IME; actual
  exact-HEAD unsigned CI/IPA and independent review. Existing E/F physical gates remain
  separate. The owner explicitly requests code/build delivery while testing the base
  remote; this does not establish physical compatibility or wake readiness.

## 8. Active milestone
**Current bounded TV task (§7.3 G):** deliver app launching, bookmarks and a useful TV
library while the owner tests the base IPA. Base code/build readiness is recorded above;
physical pairing → control → standby → iPad wake (including 30 minutes) remains pending.
Existing PC acceptance also remains outstanding as recorded below.

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
Existing PC stage **5. Windows helper and foreground-aware layouts (§7.2)** remains pending
physical acceptance — the
companion app, secure local pairing and per-app/foreground layout contract are defined by spec
commit `fb77782` and implemented by commit `c8babce` (`feat(windows): configure foreground app
layouts [spec fb77782]`): Windows C# helper + iPad `BTRemote/WindowsForeground.swift` + the
user-editable JSON layout document from §7.2 F. Nothing in §7.2 may be called verified:
the C# helper builds and its dependency-free tests pass locally (67 checks); Swift cannot be
compiled on this Windows machine, so the iOS client has never been built locally and its CI build
now exists (runs `36372951698` / `36373205510`), but its behaviour is unverified and §9 item 10
stays outstanding.
The next bounded task was the operator-requested **Screamer racing gamepad** contract (§5.2): the
additive Report ID 7 composite gamepad report and the nested RACING sub-mode under GAME. It is a
new item added to the list above and does not re-order it: stage 5 (§7.2) verification stays
outstanding exactly as described above. §5.2 is now implemented in source — commits `8e9cc6b`
(`feat(game): implement Screamer racing gamepad [spec e8a62aa]`) and fixes `bfb3231`
(`fix(game): iterate gamepad subscriber set [spec e8a62aa]`) and `4fa3506`
(`fix(game): hide racing controls outside racing [spec e8a62aa]`), all following spec `e8a62aa` and
following the §4 protected-path exception exactly as written there; merged `30ccaaa` via PR #23.
The repaired code **is built**: workflow_dispatch run `36372951698` passed Test → Build → Package →
Upload on implementation HEAD `6c746a6f14a25c08063694b21796f667471a7602`, and push run `36373205510`
passed the same jobs on merge commit `30ccaaa3be6f902a4eb91f7954f322d508f830c6`; the unsigned
`.ipa` is in the run artifacts. (Historical, superseded: run `36371784190` at `8e9cc6b` FAILED in the
app build with `Set<UUID>.keys`, Test step passed; `bfb3231`/`4fa3506` fixed that.)
CI build is not functional verification: §9 item 12 (Screamer on the real iPad + Windows, including
the §5.2 M Windows descriptor-cache re-pair action) is still outstanding and is now the required next
step once that CI-built `.ipa` is installed via SideStore.

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
  (a) no separate TRACKPAD or DECK top-level mode exists — PC mode picker is `GAME | CONTROL | TOUCH`; the separate PC/TV selector follows §7.3;
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
  prompt (`NSLocalNetworkUsageDescription`, §4) appears on first helper pairing/connect
  (or an explicit TV network action, §7.3 D, if permission is still undetermined) and
  never at app launch and never on the plain §7.1 path; verify that denying it leaves the generic
  §7.1 CONTROL layout and all BLE HID pairing and existing input paths (items 4–7 / §5) completely
  unaffected.
- 11. BLE advertising recovery (§5 "BLE advertising recovery") — simple physical check: with the
  iPad already paired and controlling Windows, turn iPad Bluetooth off and back on, then return to
  the app. The app must again show Bluetooth powered on / advertising: yes **without restarting or
  reinstalling it**, and the existing Windows pair must reconnect through Windows' normal behaviour
  for an already-paired device — the HID device must NOT have to be deleted and re-paired.
  Afterwards re-run a spot check from items 4–7 (mouse move/tap/scroll, typing) to confirm nothing
  else changed. Do not record this as a latency result or as proof that all disconnect causes are
  fixed.
- 12. Screamer racing gamepad (§5.2) — physical checks only, on the real iPad + Windows; the §5.2
  implementation exists in source (`8e9cc6b` + `bfb3231` + `4fa3506`) and is now CI-built (the
  repaired code passed Test → Build → Package → Upload in workflow_dispatch run `36372951698` at
  `6c746a6` and in push run `36373205510` at merge commit `30ccaaa`; the unsigned `.ipa` artifact is
  available). The historical failed run `36371784190` at `8e9cc6b` (FAILED in the app build with
  `Set<UUID>.keys`, Test step passed) is superseded by `bfb3231`/`4fa3506`. Install the CI-built
  unsigned `.ipa` via SideStore first, then run these checks — none of them is implied by CI:
  (a) after installing the new build, Windows enumerates the iPad as a device that also exposes a
  gamepad with analog axes (if it does not, remove the paired BTRemote HID device and re-pair once,
  §5.2 M, and record that as a descriptor-cache action, not a code fix);
  (b) in Screamer's controls the device's left stick steers: turn the iPad like a steering wheel
  (rotation about the axis pointing out of the screen) left and right from the recentered pose and
  confirm the game's steering follows with the expected handedness (clockwise as the user faces
  the screen = positive/right), then press RECENTRE and confirm the baseline moves to the current
  pose and the stick returns to centre without emitting movement;
  (c) a drag anywhere on the free racing surface drives the second stick **independently while
  steering** (multitouch — the drag origin is wherever the thumb lands, no drawn pad; a touch begun
  on a button/trigger keeps driving that control instead);
  (d) right on-screen control = gas (**RT**), left on-screen control = brake (**LT**) in Screamer;
  (e) at least three ability buttons work and can be pressed together with each other, with a
  trigger and with steering;
  (f) releasing every source, and leaving RACING or GAME, leaves nothing stuck — steering recentres,
  gas, brake and all buttons release;
  (g) afterwards re-run a spot check from items 4–7 and item 11 to confirm the existing mouse,
  keyboard, DECK, Direct Input and advertising-recovery behaviour is completely unchanged.
- 13. TV target (§7.3) — separate mandatory TV hardware gate: execute §7.3 E/F, including
  saved pairing, every control/supported text, repeated Wi-Fi wake after 30-minute standby
  with the PC off, network/permission recovery, PC/TV isolation and input release.
  **NOT RUN; wake UNCONFIRMED.** This adds no claim of completed hardware acceptance.
- PC ready = all mandatory items (former MVP table 1–14) plus items 9–11 work AND lock-screen
  acceptance passes; item 12 is now required for acceptance once the CI-built implementation is
  installed on the iPad. TV ready additionally requires item 13; PC readiness alone does not
  satisfy the wake requirement.
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
- **Screamer racing gamepad (§5.2):** CONTRACT DEFINED AND IMPLEMENTED — implementation commits
  `8e9cc6b` + fixes `bfb3231` + `4fa3506` [spec `e8a62aa`], merged `30ccaaa` via PR #23; **CI-built,
  unsigned artifact available, not yet physically verified**. `GamepadReport`, Report ID 7, the
  additive gamepad bytes in the report map (303 bytes total) and the RACING input source exist in
  code, and the
  repaired code passed the full Test → Build → Package → Upload workflow (workflow_dispatch run
  `36372951698` on implementation HEAD `6c746a6f14a25c08063694b21796f667471a7602`; push run
  `36373205510` on merge commit `30ccaaa3be6f902a4eb91f7954f322d508f830c6`); the unsigned
  `BTRemote.ipa` artifact from that run is available for SideStore install. Historical, superseded:
  run `36371784190` at `8e9cc6b` FAILED in the app build (`Set<UUID>.keys`; Test step passed) and was
  fixed by `bfb3231`/`4fa3506`. CI is not functional verification: do not describe any gamepad or
  Screamer behaviour as working — §9 item 12 (iPad + Windows + Screamer, including the §5.2 M
  Windows descriptor-cache re-pair action) is still outstanding.
  See §5.2 N for the CI-vs-hardware claim boundary and §5.2 M for the Windows remove/re-pair
  fallback after the report-map change; §5.2 D is the only authorization to touch
  `BTRemote/LowEnergy/` / `BTRemote/HIDInput.swift` / `BTRemote/HIDReports.swift` for this, and
  `BTRemote/Classic/` stays untouched unless proven otherwise.
- **Native dictation RU/EN:** not implemented (🎙 placeholder).
- **Windows helper and foreground-aware layouts (§7.2):** implemented and committed in `c8babce`,
  **not verified**.
  The C# helper builds with `dotnet build` and its dependency-free tests pass locally
  (`ALL TESTS PASSED`, 67 checks). The Swift side (`BTRemote/WindowsForeground.swift`,
  `BTRemote/KeyboardView.swift`, `BTRemote/AppSettings.swift`, `BTRemote/SettingsView.swift`) has
  never been compiled locally — there is no Xcode/swift on this machine — its build is now confirmed
  by the macOS GitHub Actions job (runs `36372951698` / `36373205510`), but its behaviour still depends
  on the owner's §9 item 10 hardware session. Do not describe §7.2 as passed, and do not treat the
  previously hard-coded VS Code / Chrome / Explorer
  action sets or the fixed executable map as finished work: both are now the user-editable JSON
  document (§7.2 F).
- **Build:** no Xcode/swift on the Windows machine — "build passes" is verified up to code
  HEAD `6c746a6f14a25c08063694b21796f667471a7602` / merge `30ccaaa3be6f902a4eb91f7954f322d508f830c6`
  (CI runs `36372951698` / `36373205510`; earlier code HEADs: `aa4443c` / run `36203590465`,
  `dbe36ab` / run `35652625241`,
  `ac87c61` / run `35642707603`, `0bccedc` / run `35511332912`, `7b8679d` / run `35561610311`);
  the §5.2 gamepad code and the §7.2 F work in
  `BTRemote/WindowsForeground.swift` / `KeyboardView.swift` / `AppSettings.swift` /
  `SettingsView.swift` (committed in `c8babce`) are therefore compiled by CI, but their behaviour is
  still unverified. Any newer Swift edit is unverified without a new CI run.
  The C# companion builds and its tests pass locally (`dotnet`, .NET 8, no NuGet).
- `BTRemote/Resources/company_ids.json` + `service_uuids.json` are not in git (CI downloads them);
  `.xcodeproj` is generated, not committed.
- Imported upstream features still out of scope: iPhone remote surface and macOS Bluetooth
  Classic backend. Legacy `BTRemote/DPadView.swift` is unused by DECK and is not the new TV
  transport. Direct TV control is approved/spec-defined at §7.3, not implemented; wake unconfirmed.

## 11. PARKED work / non-goals
**PARKED — do not continue until a separate owner decision:** superlatency research — force BLE
7.5 ms interval, ETW/WPT Bluetooth tracing, other BT adapters, iPad Bluetooth Classic experiments,
private iOS APIs, ROG Omni reverse engineering, ESP32/RP2040 bridge, USB/Wi-Fi Turbo transport,
500/1000 Hz experiments. Reason: current BLE is usable; further latency hunting is worse ROI than
UX/features. (Also parked from earlier: MacBridge idea — verified it never existed; real
Windows→Mac build path = GitHub Actions macOS runner.)

**Non-goals / future work, not active:** OpenClaw, clipboard / voice / state, macros, telemetry,
accounts, cloud, process monitoring. (Windows companion / WebSocket transport and dynamic per-app
panels are no longer non-goals: they are approved and spec-defined at §7.2, implemented in `c8babce`
and CI-built (runs `36372951698` / `36373205510`); physical verification is pending.)
Approved product: iPad → BLE HID → Windows, plus iPad → local Wi-Fi → TCL TV (§7.3).
The TV network channel is not the parked Windows Wi-Fi Turbo/latency work. No cloud relay,
custom TV APK, root or mandatory ADB; no unverified Bluetooth/wake transport promise.

Runtime/model/orchestration choices are not product constraints. Applicable global instructions
and the active owner task govern them; legacy runtime files do not expand scope or authorize merge.

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
- Current verified facts (as of 2026-09-28): `main` local == `origin/main` == `30ccaaa`; newest
  green "Build unsigned IPA" run `36373205510` (on `30ccaaa`); pre-merge evidence: run `36372951698`
  (at `6c746a6`). Newest IPA = the `36373205510` artifact `btr-remote-unsigned-ipa`.
- Earlier verified facts (2026-09-26, historical, superseded by the line above): `main` local ==
  `origin/main` == `c89997f`; newest green "Build unsigned IPA" run `36203590465` at head
  `aa4443c`; newest IPA = that run's artifact `btr-remote-unsigned-ipa`.
- Never commit: credentials, downloaded IPA/ZIPs, SideStore data, probes (`rawprobe/`), temp
  folders (`.qwen/tmp`), or unrelated scratch.
- Physical verification (full §9 procedure) still awaits the user's hardware sessions.

## 13. Future phase
(Not active — any of these requires a preceding spec commit per the rule at the top of this file.)
- Phase B: Windows companion / WebSocket transport (supersedes "no Windows-side software") and
  dynamic per-app / foreground-aware layouts — the contract is defined at §7.2 (spec commits
  `b751488` / `fb77782`) and the implementation is committed in `c8babce`; that implementation is
  still unverified — the Swift client has never been compiled locally but is CI-built by runs
  `36372951698` / `36373205510`, so only the §9 item 10 hardware checks remain outstanding.
- OpenClaw; clipboard / voice / state integrations.
- Deferred backlog: TOUCH absolute digitizer (spec commit first; feature flag; separate branch;
  BLE-stack implications to be researched), gyro aim (implemented and CI-verified in `1284aca`
  + fixes `28867db`/`aa4443c`, CI run `36203590465`; physical acceptance pending per §5.1 L /
  §9), native dictation, modifier combined keycaps / sticky restore (specified in §5/§9;
  implemented in `ac87c61` + `dbe36ab` — physical verification pending), the remaining §7.2 item
  (the §9 item 10 hardware checks; the CI build of the Swift client is done — runs
  `36372951698` / `36373205510`).
