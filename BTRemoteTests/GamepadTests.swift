import Foundation
import CoreGraphics

// SPEC §5.2 N — dependency-free coverage for the Screamer racing gamepad:
// the byte-exact gamepad encoding (field order, widths, signedness, clamping at
// full scale), the §5.2 H wheel steering mapping (`RacingMapper.screenNormalDegrees`
// + `RacingSourceState.recenterSteering()`, the committed wheel fix `7be857e`
// [spec 9adfd9d]), the latest-state-wins backpressure rule and the §5.2 L lifecycle rule
// (BLE loss neutralizes every racing source; a disconnected state cannot be cached or
// carried into a fresh racing session).
//
// The wheel-steering and RECENTER coverage below is written against the committed production
// mapping (`7be857e` [spec 9adfd9d]) and has NOT been compiled or run locally: Swift cannot be
// compiled on the Windows host used for this work (§12), so this
// harness is built and run by CI: see the "Test" step in
// `.github/workflows/unsigned.yml`. Like `companion/WindowsForeground.Tests` it uses
// no test framework and no third-party dependency — the production files are
// compiled straight into the test binary.
//
// Manual local run (macOS with Xcode):
//   swiftc -swift-version 6 \
//       BTRemote/LowEnergy/HIDReports.swift \
//       BTRemote/LowEnergy/HIDProfile.swift \
//       BTRemote/GyroAim.swift \
//       BTRemoteTests/GamepadTests.swift \
//       -o .build/gamepad-tests && .build/gamepad-tests

/// SPEC §5.2 L: mirrors the guard of `HIDPeripheral.sendGamepad` — a gamepad state is only
/// cached and queued when the gamepad report characteristic exists AND at least one
/// non-inactive central is subscribed to THAT characteristic — so the unsubscribe/disconnect
/// rule is checkable without CoreBluetooth.
///
/// `gamepadSubscribedCentrals` mirrors `HIDPeripheral.gamepadSubscribedCentrals`. A plain
/// `subscribedCentrals`/`connectedCentrals` set cannot stand in for it: every report
/// characteristic shares the 0x2A4D UUID and is only distinguished by its Report Reference
/// descriptor, so the central that stays subscribed to keyboard/mouse after the gamepad
/// characteristic unsubscribes is NOT a gamepad recipient.
struct FakeGamepadTransport {
    var cached = GamepadReport.zero.data
    var pending = GamepadPendingState()
    /// The generic shared slot (`HIDPeripheral.pendingBroadcast`). A gamepad payload must
    /// never land here: `peripheralManagerIsReadyToUpdateSubscribers` drains it first and a
    /// later release/unsubscribe clears `pending` only, so a gamepad state parked in it would
    /// be replayed on its own and violate latest-state-wins/release semantics.
    var pendingBroadcast: Data?
    var sentCount = 0
    /// centrals subscribed to the Report ID 7 (gamepad) characteristic
    var gamepadSubscribedCentrals: Set<UUID> = []
    /// the same central, still subscribed to keyboard/mouse only — never a gamepad recipient
    var keyboardMouseOnlyCentrals: Set<UUID> = []

    mutating func sendGamepad(_ report: GamepadReport) {
        guard !gamepadSubscribedCentrals.isEmpty else { return }
        cached = report.data
        // Stands in for a rejected `updateValue`: the newest state is held, never queued.
        pending.replace(report.data)
        sentCount += 1
    }

    /// Mirrors the gamepad branch of `HIDPeripheral.didSubscribeTo`: the cached bootstrap
    /// payload a just-subscribed host receives is a gamepad state like any other, so it goes
    /// through `updateGamepadValue` (the single latest-wins slot), never through generic
    /// `updateValue`, whose rejected write would be parked in `pendingBroadcast`.
    mutating func didSubscribeGamepad(cached newest: Data) {
        guard !gamepadSubscribedCentrals.isEmpty else { return }
        pending.replace(newest)
        sentCount += 1
    }

    /// Mirrors generic `updateValue`: a rejected non-gamepad send is parked in the shared
    /// `pendingBroadcast` slot. Kept to prove the gamepad path never touches that slot.
    mutating func updateValue(_ data: Data) {
        pendingBroadcast = data
    }
}

@main
struct GamepadTests {
    static func main() {
        var failures: [String] = []
        var checks = 0

        func expect(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.append(name) }
        }

        func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            checks += 1
            if actual != expected {
                failures.append("\(name): expected \(expected), got \(actual)")
            }
        }

        func expectClose(_ actual: Double, _ expected: Double, _ tolerance: Double,
                         _ name: String) {
            checks += 1
            if !(abs(actual - expected) <= tolerance) || actual.isNaN {
                failures.append("\(name): expected \(expected) ±\(tolerance), got \(actual)")
            }
        }

        // The two helpers below only BUILD inputs for the production mapping. The
        // quaternion→steering arithmetic under test is never recomputed in this harness.

        /// A unit quaternion for a right-hand rotation of `degrees` about `axis`.
        func quaternion(_ axisX: Double, _ axisY: Double, _ axisZ: Double,
                        degrees: Double) -> RacingQuaternion {
            let half = degrees * Double.pi / 360
            let s = sin(half)
            let n = sqrt(axisX * axisX + axisY * axisY + axisZ * axisZ)
            return RacingQuaternion(w: cos(half), x: axisX * s / n, y: axisY * s / n,
                                    z: axisZ * s / n)
        }

        /// Hamilton product `a ⊗ b`: composes a pose that is `degrees` of rotation about
        /// an axis of a nonidentity baseline.
        func multiply(_ a: RacingQuaternion, _ b: RacingQuaternion) -> RacingQuaternion {
            RacingQuaternion(
                w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
                x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
            )
        }

        // MARK: report IDs and Report Reference (SPEC §5.2 B/C)

        expectEqual(
            [
                ReportID.mouse.rawValue,
                ReportID.keyboard.rawValue,
                ReportID.keyboardLEDs.rawValue,
                ReportID.battery.rawValue,
                ReportID.systemControl.rawValue,
                ReportID.consumerControl.rawValue,
            ],
            [1, 2, 3, 4, 5, 6],
            "existing report IDs 1...6 are unchanged"
        )
        expectEqual(ReportID.gamepad.rawValue, 7, "the gamepad takes the next unused report ID 7")
        expectEqual(
            Set([
                ReportID.mouse.rawValue, ReportID.keyboard.rawValue, ReportID.keyboardLEDs.rawValue,
                ReportID.battery.rawValue, ReportID.systemControl.rawValue,
                ReportID.consumerControl.rawValue, ReportID.gamepad.rawValue,
            ]).count,
            7,
            "report IDs stay unique"
        )
        expectEqual(
            ReportID.gamepad.descriptor(.input),
            Data([7, 1]),
            "the gamepad Report Reference descriptor is [7, input]"
        )

        // MARK: byte-exact fixed-length payload (SPEC §5.2 C)

        expectEqual(
            Array(GamepadReport.zero.data),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "the neutral report is seven zero bytes (axes 0, triggers 0, all bits released)"
        )
        expectEqual(
            GamepadReport(buttons: [.a, .b, .x], lx: -127, ly: 0, rx: 127, ry: 0, lt: 255, rt: 128).data,
            Data([0x07, 0x81, 0x00, 0x7F, 0x00, 0xFF, 0x80]),
            "field order and widths are buttons + four signed axes + two unsigned triggers"
        )
        expectEqual(
            GamepadReport(buttons: [.a, .b, .x], lx: -127, ly: 0, rx: 127, ry: 0, lt: 255, rt: 128).data.count,
            7,
            "the payload is exactly 7 bytes with no leading Report ID byte"
        )
        expectEqual(GamepadReport.clampSigned(-128), -127, "signed axes clamp to -127")
        expectEqual(GamepadReport.clampSigned(127), 127, "signed clamp keeps the positive extreme")
        expectEqual(
            Array(GamepadReport(buttons: [.a], lx: -128, rx: 127, lt: 255, rt: 255).data),
            [0x01, 0x81, 0x00, 0x7F, 0x00, 0xFF, 0xFF],
            "out-of-range field values are clamped before they are sent"
        )
        // SPEC §5.2 C: buttons 1–3 occupy the three defined ability bits; bits 3–7 are
        // reserved and always 0, so a malformed/future rawValue must not leak them.
        expectEqual(
            Array(GamepadReport(buttons: GamepadButtons(rawValue: 0xFF), lx: -127, ly: 0,
                                rx: 127, ry: 0, lt: 255, rt: 128).data),
            [0x07, 0x81, 0x00, 0x7F, 0x00, 0xFF, 0x80],
            "a rawValue with reserved bits set still sends only bits 0–2"
        )

        // MARK: absolute steering mapping (SPEC §5.2 H)

        expectEqual(RacingTuning.gyroDeadzoneDegrees, 2, "deadzone starts at ~2 degrees")
        expectEqual(RacingTuning.gyroFullLockDegrees, 32, "full lock starts at 32 degrees")
        expectEqual(RacingTuning.expo, 1.4, "expo starts at 1.4")
        expectEqual(RacingMapper.axis(fromAngle: 1), 0, "inside the deadzone the axis stays 0")
        expectEqual(RacingMapper.axis(fromAngle: 2), 0, "at the deadzone the axis stays 0")
        expectEqual(RacingMapper.axis(fromAngle: 32), 127, "full lock reaches full-scale deflection")
        expectEqual(RacingMapper.axis(fromAngle: -32), -127, "steering left is negative")
        expectEqual(RacingMapper.axis(fromAngle: 64), 127, "beyond full lock clamps to full scale")
        expectEqual(RacingMapper.axis(fromAngle: -64), -127, "beyond full lock clamps to -full scale")
        // Half of the 2...32 degree travel (17 degrees) with expo 1.4: 0.5^1.4 * 127 = 48.16 -> 48.
        expectEqual(RacingMapper.axis(fromAngle: 17), 48, "expo 1.4 shapes the mid-range ramp")
        expectEqual(RacingMapper.axis(fromAngle: -17), -48, "the expo ramp keeps the sign")

        // MARK: floating free-surface drag (SPEC §5.2 I)

        expectEqual(RacingTuning.touchDeadzonePoints, 8, "the floating drag deadzone is ~8 pt")
        expectEqual(RacingTuning.touchFullTravelPoints, 100, "full travel is ~100 pt")
        expectEqual(RacingMapper.axis(fromDrag: 4), 0, "a drag inside the deadzone produces no RX")
        expectEqual(RacingMapper.axis(fromDrag: 8), 0, "a drag at the deadzone produces no RX")
        expectEqual(RacingMapper.axis(fromDrag: 100), 127, "full drag travel gives full-scale X")
        expectEqual(RacingMapper.axis(fromDrag: -100), -127, "dragging left gives negative X")
        expectEqual(RacingMapper.axis(fromDrag: 200), 127, "a drag past full travel clamps")
        expectEqual(RacingMapper.axis(fromDrag: 54), 64, "half travel gives half-scale X")

        // MARK: racing sources release independently, then one neutral report (SPEC §5.2 E/I/J/L)

        var racing = RacingSourceState()
        racing.setButton(.a, pressed: true)
        racing.setButton(.b, pressed: true)
        racing.setButton(.x, pressed: true)
        racing.setTrigger(.brake, pressed: true)
        racing.setTrigger(.gas, pressed: true)
        racing.beginTouch(at: CGPoint(x: 40, y: 20))
        racing.moveTouch(to: CGPoint(x: 140, y: 20))
        expectEqual(
            Array(racing.gamepad.data),
            [0x07, 0x00, 0x00, 0x7F, 0x00, 0xFF, 0xFF],
            "three ability bits, both pedals and the floating drag are held in one report"
        )
        racing.setButton(.b, pressed: false)
        expectEqual(
            Array(racing.gamepad.data),
            [0x05, 0x00, 0x00, 0x7F, 0x00, 0xFF, 0xFF],
            "releasing one ability button clears only its own bit, the others stay held"
        )
        racing.setTrigger(.gas, pressed: false)
        expectEqual(
            Array(racing.gamepad.data),
            [0x05, 0x00, 0x00, 0x7F, 0x00, 0xFF, 0x00],
            "releasing gas clears RT while the brake is still held"
        )
        racing.setTrigger(.brake, pressed: false)
        expectEqual(
            Array(racing.gamepad.data),
            [0x05, 0x00, 0x00, 0x7F, 0x00, 0x00, 0x00],
            "releasing the brake clears LT while the held buttons and RX stay untouched"
        )
        racing.endTouch()
        expectEqual(
            Array(racing.gamepad.data),
            [0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "ending the floating drag clears RX only"
        )
        // SPEC §5.2 L: leaving RACING (mode switch, leaving GAME, backgrounding, link loss)
        // goes through the one state-neutralization helper: every source returns to neutral
        // in a single newest-state report.
        racing.neutralize()
        expectEqual(
            Array(racing.gamepad.data),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "the neutralization helper clears every field: axes 0, triggers 0, all bits released"
        )
        expect(racing.touchOrigin == nil, "neutralizing drops the floating drag origin")
        expect(racing.heldButtons.isEmpty, "neutralizing releases every ability button")

        // SPEC §5.2 C/E: steering is one field of the same single report as the pedals and
        // the ability buttons. The gyro source writes `racing.gamepad.lx` (the same state the
        // touch/button/pedal sources write their fields into) and re-sends the whole report.
        var full = RacingSourceState()
        full.gamepad.lx = RacingMapper.axis(fromAngle: -32)
        full.setTrigger(.gas, pressed: true)
        full.setButton(.a, pressed: true)
        expectEqual(
            Array(full.gamepad.data),
            [0x01, 0x81, 0x00, 0x00, 0x00, 0x00, 0xFF],
            "steering, gas and an ability button are held in one report"
        )

        // MARK: wheel steering = signed rotation about the device screen-normal (SPEC §5.2 H/N)

        // These checks call the ACTUAL production mapping the iOS build uses
        // (`RacingMapper.screenNormalDegrees` and `RacingSourceState.recenterSteering()`, the
        // committed wheel fix `7be857e` [spec 9adfd9d]). Nothing here re-implements the
        // quaternion→steering arithmetic; the helpers above only build the inputs.

        let neutralPose = RacingQuaternion(w: 1, x: 0, y: 0, z: 0)
        let heldPose = multiply(quaternion(1, 0, 0, degrees: 40),
                                quaternion(0, 0, 1, degrees: 25))

        // SPEC §5.2 H: a clockwise turn as the user faces the screen (a right-hand rotation
        // about the negated device screen normal) must produce POSITIVE steering.
        expectClose(RacingMapper.screenNormalDegrees(from: neutralPose,
                                                    to: quaternion(0, 0, -1, degrees: 32)),
                    RacingTuning.gyroFullLockDegrees, 1e-6,
                    "a clockwise turn about the device screen-normal is positive steering")
        // The opposite (counterclockwise) turn must produce NEGATIVE steering.
        expectClose(RacingMapper.screenNormalDegrees(from: neutralPose,
                                                    to: quaternion(0, 0, 1, degrees: 32)),
                    -RacingTuning.gyroFullLockDegrees, 1e-6,
                    "a counterclockwise turn about the device screen-normal is negative steering")

        // SPEC §5.2 H/N: a neutral and a held starting orientation. A device that never moved
        // from the recorded pose maps to exactly zero, so the stick cannot stay deflected.
        expectEqual(RacingMapper.screenNormalDegrees(from: neutralPose, to: neutralPose), 0,
                    "a device that never moved from the recorded neutral pose maps to zero")
        expectEqual(RacingMapper.screenNormalDegrees(from: heldPose, to: heldPose), 0,
                    "a device that never moved from the recorded held pose maps to zero")
        let turnedFromHeld = multiply(heldPose, quaternion(0, 0, -1, degrees: 32))
        let firstSteeringSample = RacingMapper.screenNormalDegrees(from: heldPose,
                                                                  to: turnedFromHeld)
        expectClose(firstSteeringSample, RacingTuning.gyroFullLockDegrees, 1e-6,
                    "a clockwise turn from a nonidentity (held) baseline is still positive")
        expectEqual(RacingMapper.screenNormalDegrees(from: heldPose, to: turnedFromHeld),
                    firstSteeringSample,
                    "repeating the same held pose gives the same steering angle")

        // SPEC §5.2 H: because the axis is the device's own screen normal the result must not
        // depend on how the device is held, so both landscape orientations stay symmetric.
        let landscapeLeft = quaternion(0, 0, 1, degrees: 90)
        let landscapeRight = quaternion(0, 0, -1, degrees: 90)
        expectClose(RacingMapper.screenNormalDegrees(from: landscapeLeft,
                                                    to: multiply(landscapeLeft,
                                                                quaternion(0, 0, -1,
                                                                          degrees: 32))),
                    RacingTuning.gyroFullLockDegrees, 1e-6,
                    "landscape left: the same clockwise turn gives the same positive steering")
        expectClose(RacingMapper.screenNormalDegrees(from: landscapeRight,
                                                    to: multiply(landscapeRight,
                                                                quaternion(0, 0, -1,
                                                                          degrees: 32))),
                    RacingTuning.gyroFullLockDegrees, 1e-6,
                    "landscape right: the same clockwise turn gives the same positive steering")

        // SPEC §5.2 N: `q` and `-q` describe the same rotation, so a turn handed to the
        // production mapping in either representation must map identically.
        let turnedNegated = RacingQuaternion(w: -turnedFromHeld.w, x: -turnedFromHeld.x,
                                            y: -turnedFromHeld.y, z: -turnedFromHeld.z)
        expectEqual(RacingMapper.screenNormalDegrees(from: heldPose, to: turnedNegated),
                    firstSteeringSample,
                    "q and -q (the same rotation) map to the same steering angle")

        // SPEC §5.2 H/N: a pure device-X (somersault) rotation is not steering, from either a
        // neutral or a nonidentity baseline.
        expectEqual(RacingMapper.screenNormalDegrees(from: neutralPose,
                                                    to: quaternion(1, 0, 0, degrees: 45)), 0,
                    "a pure device-X (somersault) rotation produces no steering")
        expectClose(RacingMapper.screenNormalDegrees(from: heldPose,
                                                    to: multiply(heldPose,
                                                                quaternion(1, 0, 0,
                                                                          degrees: 45))),
                    0, 1e-9,
                    "a pure device-X rotation from a held pose also produces no steering")

        // SPEC §5.2 H: the angle produced by the real mapping then goes through the existing
        // deadzone/full-lock/expo ramp.
        let deadzoneSample = RacingMapper.screenNormalDegrees(
            from: neutralPose, to: quaternion(0, 0, -1, degrees: 1)
        )
        expectEqual(RacingMapper.axis(fromAngle: deadzoneSample), 0,
                    "a 1 degree quaternion-level turn stays inside the steering deadzone")
        let fullLockSample = RacingMapper.screenNormalDegrees(
            from: neutralPose, to: quaternion(0, 0, -1, degrees: 32)
        )
        expectEqual(RacingMapper.axis(fromAngle: fullLockSample), 127,
                    "a 32 degree quaternion-level turn gives full-scale positive left-stick X")
        let beyondLockSample = RacingMapper.screenNormalDegrees(
            from: neutralPose, to: quaternion(0, 0, -1, degrees: 45)
        )
        expectEqual(RacingMapper.axis(fromAngle: beyondLockSample), 127,
                    "a rotation beyond full lock clamps to full scale")
        let ccwLockSample = RacingMapper.screenNormalDegrees(
            from: neutralPose, to: quaternion(0, 0, 1, degrees: 32)
        )
        expectEqual(RacingMapper.axis(fromAngle: ccwLockSample), -127,
                    "a 32 degree counterclockwise turn gives full-scale negative left-stick X")

        // MARK: RECENTER clears LX and preserves every other held field (SPEC §5.2 H/E/J/L)

        // This exercises the production operation `RacingSourceState.recenterSteering()`, the
        // one `GyroAimController.recenter()` calls, so the "clear steering, keep everything
        // else" rule is not duplicated in the harness.
        var recentered = RacingSourceState()
        recentered.setButton(.a, pressed: true)
        recentered.setButton(.b, pressed: true)
        recentered.setButton(.x, pressed: true)
        recentered.setTrigger(.brake, pressed: true)
        recentered.setTrigger(.gas, pressed: true)
        recentered.beginTouch(at: CGPoint(x: 40, y: 20))
        recentered.moveTouch(to: CGPoint(x: 140, y: 20))
        recentered.gamepad.lx = RacingMapper.axis(fromAngle: fullLockSample)
        expectEqual(recentered.gamepad.lx, 127,
                    "a full-lock turn holds LX at full scale before RECENTER")
        recentered.recenterSteering()
        expectEqual(recentered.gamepad.lx, 0,
                    "RECENTER clears a steering deflection that was already transmitted")
        expectEqual(recentered.gamepad.rx, 127, "RECENTER keeps the held floating drag")
        expectEqual(recentered.gamepad.lt, 255, "RECENTER keeps the held brake pedal")
        expectEqual(recentered.gamepad.rt, 255, "RECENTER keeps the held gas pedal")
        let heldButtonsAfterRecenter: GamepadButtons = [.a, .b, .x]
        expect(recentered.gamepad.buttons == heldButtonsAfterRecenter,
               "RECENTER keeps every held ability button")
        expect(recentered.touchOrigin != nil, "RECENTER keeps the floating drag origin")
        expectEqual(recentered.heldButtons.count, 3, "RECENTER keeps all three ability bits")
        expectEqual(
            Array(recentered.gamepad.data),
            [0x07, 0x00, 0x00, 0x7F, 0x00, 0xFF, 0xFF],
            "after RECENTER one report still carries the drag, both pedals and all buttons"
        )

        // MARK: BLE link loss and a fresh racing session (SPEC §5.2 L)

        // Everything the player can hold at once is held when the link drops.
        var session = RacingSourceState()
        session.setTrigger(.brake, pressed: true)
        session.setButton(.a, pressed: true)
        session.beginTouch(at: CGPoint(x: 40, y: 20))
        session.moveTouch(to: CGPoint(x: 140, y: 20))
        expectEqual(
            Array(session.gamepad.data),
            [0x01, 0x00, 0x00, 0x7F, 0x00, 0xFF, 0x00],
            "a racing session can hold a pedal, an ability button and the floating drag at once"
        )

        // The BLE link drops (or the radio is reset): `KeyboardView` reacts to the published
        // `lowEnergy` connection/service state, so `GyroAimController.stop()` runs — it stops
        // the motion source and neutralizes the racing sources. With no active BLE recipient
        // `HIDPeripheral.sendGamepad` must neither send nor cache anything.
        var transport = FakeGamepadTransport()
        transport.sendGamepad(session.gamepad)
        expectEqual(transport.sentCount, 0, "no gamepad report is sent while no BLE recipient is active")
        expect(transport.pending.data == nil, "no gamepad state is queued for a disconnected host")
        expectEqual(
            Array(transport.cached),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "a non-neutral state is never cached while there is no active BLE recipient"
        )
        session.neutralize()
        expectEqual(
            Array(session.gamepad.data),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "BLE disconnect neutralizes every racing field: axes 0, triggers 0, all bits released"
        )

        // Reconnect: `configureGyro()` restarts the same motion pipeline and `start()` resets
        // the racing state, so a pre-disconnect held state cannot survive into a new session.
        session = RacingSourceState()
        expectEqual(session.gamepad, GamepadReport.zero, "a fresh racing session starts from one neutral state")
        transport.gamepadSubscribedCentrals = [UUID()]
        transport.sendGamepad(session.gamepad)
        expectEqual(transport.sentCount, 1, "the reconnected host receives the newest state")
        expectEqual(transport.cached, GamepadReport.zero.data,
                    "the reconnected host gets neutral, never the pre-disconnect held state")
        expect(transport.pending.data == GamepadReport.zero.data,
               "the newest state after reconnect is the neutral release, not the stale held one")

        // MARK: latest-state-wins backpressure (SPEC §5.2 E)

        var pending = GamepadPendingState()
        expect(pending.data == nil, "no gamepad state is held before the first send")
        let first = GamepadReport(buttons: [.a], lx: 100, rt: 255).data
        pending.replace(first)
        expect(pending.data == first, "a state produced while not ready is held pending")
        let second = GamepadReport(buttons: [.a, .b], lx: -64, rt: 0).data
        pending.replace(second)
        expect(pending.data == second, "a newer state replaces the pending one, it is never queued")
        expect(pending.take() == second, "exactly one newest state is re-sent on ready")
        expect(pending.data == nil, "the re-sent state is not held any more")
        expect(pending.take() == nil, "nothing is ever replayed after it has been drained")

        // MARK: a release replaces the stale held state (SPEC §5.2 E/J/L)

        // The player released what was held, so the neutral release payload is the newest
        // state: it must be the one that is re-sent, and it must not be replayed again.
        var released = GamepadPendingState()
        released.replace(GamepadReport(buttons: [.a], lx: 100, rt: 255).data)
        let releasePayload = GamepadReport.zero.data
        released.replace(releasePayload)
        expect(released.data == releasePayload,
               "a release replaces the stale pending state before anything is taken")
        expect(released.take() == releasePayload,
               "the release payload is the one state that is re-sent")
        expect(released.take() == nil, "a released state is never replayed")

        // MARK: readiness guard in the shared ready-to-update callback (SPEC §5.2 E)

        // `peripheralManagerIsReadyToUpdateSubscribers` drains the broadcast and the mouse
        // reports first; if either was rejected again the gamepad must not push a report
        // and must not consume its one latest-wins state.
        var backlog = GamepadPendingState()
        let newest = GamepadReport(buttons: [.b], lx: -64, lt: 255).data
        backlog.replace(newest)
        expect(backlog.take(ifReady: false) == nil,
               "the gamepad is not pushed after readiness was cleared by another report's drain")
        expect(backlog.data == newest,
               "the latest gamepad state is retained instead of being consumed and lost")
        expect(backlog.take(ifReady: true) == newest,
               "the retained state is re-sent once the stack is ready again")
        expect(backlog.data == nil, "and the re-sent state is not held any more")

        // MARK: gamepad unsubscribe with keyboard/mouse still subscribed (SPEC §5.2 L)

        // Review finding: unsubscribing from the gamepad does not disconnect the central,
        // because the same central is usually still subscribed to keyboard/mouse. A gyro
        // sample that still arrives afterwards must not send a non-neutral state, and it
        // must not repopulate the read-back cache with one.
        var detached = FakeGamepadTransport()
        detached.gamepadSubscribedCentrals = []            // gamepad characteristic unsubscribed
        detached.keyboardMouseOnlyCentrals = [UUID()]      // same central, keyboard/mouse only
        var stillHeld = RacingSourceState()
        stillHeld.setTrigger(.gas, pressed: true)
        stillHeld.setButton(.a, pressed: true)
        stillHeld.beginTouch(at: CGPoint(x: 40, y: 20))
        stillHeld.moveTouch(to: CGPoint(x: 140, y: 20))
        detached.sendGamepad(stillHeld.gamepad)
        expectEqual(detached.sentCount, 0,
                    "a central that only subscribes to keyboard/mouse is not a gamepad recipient")
        expect(detached.pending.data == nil,
               "no gamepad state is queued for a central that unsubscribed from the gamepad")
        expectEqual(
            Array(detached.cached),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            "a non-neutral state is never cached when the gamepad characteristic is unsubscribed"
        )

        // MARK: the didSubscribe bootstrap uses the same latest-wins gamepad slot (SPEC §5.2 E/L)

        // Backpressure: the stack cannot accept a notification and a host subscribes to the
        // gamepad characteristic, so the cached bootstrap payload has to be held. It must be
        // held in the gamepad's own latest-wins slot and never in the shared `pendingBroadcast`
        // slot, otherwise a later button release/unsubscribe cannot clear it and
        // `drainPendingBroadcast()` would replay a stale non-neutral state.
        var bootstrap = FakeGamepadTransport()
        bootstrap.gamepadSubscribedCentrals = [UUID()]
        bootstrap.sendGamepad(GamepadReport(buttons: [.a], lx: 100, rt: 255))
        let heldState = bootstrap.cached
        bootstrap.didSubscribeGamepad(cached: heldState)
        expect(bootstrap.pendingBroadcast == nil,
               "a bootstrap gamepad state is never parked in the shared pendingBroadcast slot")
        expect(bootstrap.pending.data == heldState,
               "the bootstrap state is held in the single gamepad latest-wins slot")
        // The player releases everything and the link drops: the newest state is neutral, so
        // the only thing that can still be re-sent is that neutral release.
        bootstrap.sendGamepad(GamepadReport.zero)
        expect(bootstrap.pending.data == GamepadReport.zero.data,
               "a release after the bootstrap replaces the stale bootstrap state")
        expect(bootstrap.pending.take() == GamepadReport.zero.data,
               "the ready drain re-sends the newest neutral state only")
        expect(bootstrap.pending.data == nil, "and nothing is ever replayed a second time")
        // Non-gamepad report behavior is unchanged: a rejected generic send still lands in the
        // shared `pendingBroadcast` slot.
        var generic = FakeGamepadTransport()
        generic.updateValue(KeyboardReport.zero.data)
        expect(generic.pendingBroadcast == KeyboardReport.zero.data,
               "a rejected non-gamepad report still uses the shared pendingBroadcast slot")

        // MARK: nested RACING source and existing sources (SPEC §5.2 G)

        expectEqual(GameInputMode.touch.rawValue, "touch", "the persisted touch source still resolves")
        expectEqual(GameInputMode.gyro.rawValue, "gyro", "the persisted gyro source still resolves")
        expectEqual(GameInputMode.hybrid.rawValue, "hybrid", "the persisted hybrid source still resolves")
        expectEqual(GameInputMode.racing.rawValue, "racing", "RACING is a nested GAME input source")
        expectEqual(GameInputMode(rawValue: "trackpad"), nil, "no fourth top-level mode was added")
        expectEqual(GamepadButtons.a.rawValue, 1 << 0, "ability button 1 uses bit0")
        expectEqual(GamepadButtons.b.rawValue, 1 << 1, "ability button 2 uses bit1")
        expectEqual(GamepadButtons.x.rawValue, 1 << 2, "ability button 3 uses bit2")
        expectEqual(
            GamepadReport(buttons: [.a, .b, .x], lt: 200, rt: 255).data,
            Data([0x07, 0x00, 0x00, 0x00, 0x00, 200, 255]),
            "three ability buttons and both pedals coexist in one report"
        )

        // MARK: report map is append-only (SPEC §5.2 C)

        let legacyMap: [UInt8] = [
            0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09,
            0x19, 0x01, 0x29, 0x03, 0x75, 0x01, 0x95, 0x03, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02,
            0x95, 0x05, 0x81, 0x03, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x75, 0x08,
            0x95, 0x03, 0x15, 0x81, 0x25, 0x7F, 0x81, 0x06, 0xC0, 0xC0,
            // keyboard input + LED output (report IDs 2 and 3)
            0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x02, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
            0x75, 0x01, 0x95, 0x08, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08,
            0x81, 0x01, 0x19, 0x00, 0x29, 0xDD, 0x95, 0x06, 0x25, 0xDD, 0x81, 0x00, 0x85, 0x03,
            0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x95, 0x05, 0x75, 0x01, 0x25, 0x01, 0x91, 0x02,
            0x95, 0x03, 0x91, 0x03, 0xC0,
            // battery via HID (report ID 4)
            0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x04, 0x05, 0x06, 0x09, 0x20, 0x75, 0x08,
            0x95, 0x01, 0x15, 0x00, 0x25, 0x64, 0x81, 0x02, 0xC0,
            // system control (report ID 5)
            0x05, 0x01, 0x09, 0x80, 0xA1, 0x01, 0x85, 0x05, 0x09, 0x81, 0x09, 0x82, 0x09, 0x8E,
            0x09, 0xA8, 0x09, 0x8F, 0x09, 0x85, 0x09, 0x86, 0x09, 0xA7, 0x75, 0x01, 0x95, 0x08,
            0x15, 0x00, 0x25, 0x01, 0x81, 0x06, 0xC0,
            // consumer control (report ID 6)
            0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x06, 0x19, 0x00, 0x2A, 0x74, 0x01,
            0x75, 0x10, 0x95, 0x01, 0x15, 0x00, 0x26, 0x74, 0x01, 0x81, 0x00,
            0x1A, 0x81, 0x01, 0x2A, 0xCB, 0x01, 0x95, 0x01, 0x75, 0x08, 0x15, 0x01, 0x25, 0x4B,
            0x81, 0x00, 0x1A, 0x01, 0x02, 0x2A, 0xB0, 0x02, 0x25, 0xB0, 0x81, 0x00,
            0xA1, 0x03, 0x19, 0x00, 0x29, 0xFF, 0x95, 0x01, 0x75, 0x08, 0x15, 0x00, 0x25, 0xFF,
            0x81, 0x00, 0xC0, 0xC0,
        ]
        expectEqual(legacyMap.count, 239, "the legacy map literal is the original 239 bytes")
        expectEqual(
            Array(HIDProfile.reportMapData.prefix(239)),
            legacyMap,
            "every existing report-map byte is unchanged (append-only)"
        )
        let gamepadBlock: [UInt8] = [
            0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x07, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
            0x75, 0x01, 0x95, 0x03, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02, 0x75, 0x05, 0x95, 0x01,
            0x81, 0x03, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34, 0x75, 0x08,
            0x95, 0x04, 0x15, 0x81, 0x25, 0x7F, 0x81, 0x02, 0x09, 0x32, 0x09, 0x35, 0x95, 0x02,
            0x15, 0x00, 0x26, 0xFF, 0x00, 0x81, 0x02, 0xC0,
        ]
        expectEqual(
            Array(HIDProfile.reportMapData.suffix(64)),
            gamepadBlock,
            "the appended gamepad block is byte-exact (Generic Desktop Game Pad, buttons, signed axes, unsigned triggers)"
        )
        expectEqual(HIDProfile.reportMapData.count, 239 + 64, "the report map is 303 bytes in total")

        if failures.isEmpty {
            print("GamepadTests: all \(checks) checks passed")
            exit(0)
        }
        print("GamepadTests: \(failures.count) of \(checks) checks FAILED")
        for failure in failures {
            print("  - \(failure)")
        }
        exit(1)
    }
}
