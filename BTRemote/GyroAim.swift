import Foundation
import CoreGraphics
import SwiftUI
#if os(iOS)
    import CoreMotion
#endif

/// GAME input source (SPEC §5.1 A/I). Touch stays the default; gyro, hybrid and
/// racing are only reachable from the temporary GAME chrome. SPEC §5.2 G: `racing`
/// is nested inside GAME — it is not a fourth top-level mode — and it does not
/// change the behaviour, labels, sensitivity defaults, persistence or
/// unavailable-status handling of `touch`, `gyro` or `hybrid`.
enum GameInputMode: String {
    case touch
    case gyro
    case hybrid
    case racing
}

/// SPEC §5.2 H/I: compile-time tuning defaults for the first playable racing build
/// (the operator-requested starting values, to be corrected on hardware). SPEC §5.2 K
/// forbids user-configurable remapping, layouts or settings, so these stay constants.
enum RacingTuning {
    /// Degrees of rotation about the device screen-normal from the recentered baseline
    /// that still produce no steering (SPEC §5.2 H).
    static let gyroDeadzoneDegrees: Double = 2
    /// Degrees of that rotation from the baseline that produce full-scale stick
    /// deflection (SPEC §5.2 H).
    static let gyroFullLockDegrees: Double = 32
    /// Response curve exponent (SPEC §5.2 H: 1.3–1.5, start at 1.4).
    static let expo: Double = 1.4
    /// Points of drag from a touch's own origin that produce no right-stick movement.
    static let touchDeadzonePoints: CGFloat = 8
    /// Points of drag from a touch's origin that produce full-scale right-stick X.
    static let touchFullTravelPoints: CGFloat = 100
    /// Full-scale value of one signed 8-bit axis (the report map's -127...127 range).
    static let fullScale: Double = 127
}

/// SPEC §5.2 H: one device attitude sample as a unit quaternion. Declared outside the
/// iOS guard and not `private` so the dependency-free Swift harness can construct
/// quaternion inputs for `RacingMapper.screenNormalDegrees` without CoreMotion or
/// UIKit (SPEC §5.2 N).
struct RacingQuaternion: Sendable {
    var w: Double
    var x: Double
    var y: Double
    var z: Double
}

/// SPEC §5.2 H/I: pure angle/distance -> signed axis mapping. Deliberately free of
/// UIKit, CoreMotion and CoreBluetooth so the mapping can be compiled and tested by
/// a dependency-free Swift harness (SPEC §5.2 N).
enum RacingMapper {
    /// SPEC §5.2 H: the signed rotation, in degrees, about the device screen-normal
    /// (the device's own Z axis) between the recentered `baseline` attitude and the
    /// `current` attitude — the motion of turning a steering wheel while facing the
    /// screen. Because that axis is the device's own screen normal, the result does not
    /// depend on how the device is held, so landscape left and right stay symmetric.
    /// A clockwise turn as the user faces the screen is positive, the opposite turn
    /// negative (SPEC §5.2 H: clockwise = positive left-stick X).
    ///
    /// The rotation is the incremental quaternion `baseline⁻¹ ⊗ current` — the same
    /// product the §5.1 aim path already computes — reduced to its Z (screen-normal)
    /// component. `q` and `-q` describe the same rotation, so the operand whose dot
    /// product with the baseline is negative is negated first: that keeps the shortest
    /// representation and stops a rotation from ever being taken the long way round.
    /// A rotation whose vector part has zero norm returns exactly zero, so a device
    /// returned to the recorded pose maps to a centred stick (SPEC §5.2 H/N).
    static func screenNormalDegrees(from baseline: RacingQuaternion,
                                    to current: RacingQuaternion) -> Double
    {
        // Shortest q/-q representation of the increment.
        var c = current
        if baseline.w * c.w + baseline.x * c.x
            + baseline.y * c.y + baseline.z * c.z < 0
        {
            c = RacingQuaternion(w: -c.w, x: -c.x, y: -c.y, z: -c.z)
        }
        // Incremental rotation from the baseline: q_baseline⁻¹ ⊗ q_current.
        let w = baseline.w * c.w + baseline.x * c.x
            + baseline.y * c.y + baseline.z * c.z
        let x = baseline.w * c.x - baseline.x * c.w
            - baseline.y * c.z + baseline.z * c.y
        let y = baseline.w * c.y - baseline.y * c.w
            + baseline.x * c.z - baseline.z * c.x
        let z = baseline.w * c.z - baseline.z * c.w
            - baseline.x * c.y + baseline.y * c.x
        let norm = sqrt(x * x + y * y + z * z)
        guard norm > 1e-9 else { return 0 }
        // Rotation vector (axis × angle) about the device Z (screen-normal) axis,
        // converted to degrees. Right-hand rule about +Z is counter-clockwise for a
        // user facing the screen, hence the sign flip: clockwise is positive.
        let radians = 2.0 * atan2(norm, w) / norm
        return -z * radians * 180.0 / Double.pi
    }

    /// Steering: signed left-stick X from a screen-normal rotation angle in degrees
    /// measured from the recentered baseline. Inside the deadzone the axis stays 0,
    /// `fullLock` degrees of rotation reaches full-scale deflection, `expo` shapes the
    /// ramp.
    static func axis(fromAngle degrees: Double,
                     deadzone: Double = RacingTuning.gyroDeadzoneDegrees,
                     fullLock: Double = RacingTuning.gyroFullLockDegrees,
                     expo: Double = RacingTuning.expo) -> Int8
    {
        guard abs(degrees) > deadzone else { return 0 }
        let travel = max(fullLock - deadzone, 1)
        let fraction = min(1, max(0, (abs(degrees) - deadzone) / travel))
        let deflection = pow(fraction, expo) * RacingTuning.fullScale
        let value = (degrees > 0 ? deflection : -deflection).rounded()
        return Int8(max(-127, min(127, value)))
    }

    /// Floating touch: signed right-stick X from the horizontal displacement of one
    /// touch, measured from that touch's own `touchesBegan` point. Right is positive,
    /// left is negative (SPEC §5.2 I).
    static func axis(fromDrag displacement: CGFloat,
                     deadzone: CGFloat = RacingTuning.touchDeadzonePoints,
                     fullTravel: CGFloat = RacingTuning.touchFullTravelPoints) -> Int8
    {
        guard abs(displacement) > deadzone else { return 0 }
        let travel = max(fullTravel - deadzone, 1)
        let fraction = min(1, max(0, (abs(displacement) - deadzone) / travel))
        let deflection = fraction * CGFloat(RacingTuning.fullScale)
        let value = (displacement > 0 ? deflection : -deflection).rounded()
        return Int8(max(-127, min(127, value)))
    }
}

/// SPEC §5.2 E/I/J/L: the pure bookkeeping behind the racing sources — which fields are
/// currently held and how each one is released without disturbing the others. Kept free of
/// CoreMotion, UIKit, CoreBluetooth and `HIDInput` so the release and neutralization rules
/// can be compiled and checked by the dependency-free CI harness (SPEC §5.2 N).
struct RacingSourceState: Sendable {
    var gamepad = GamepadReport.zero
    var touchOrigin: CGPoint?
    var heldButtons: GamepadButtons = []

    /// SPEC §5.2 I: a touch that begins on the free racing surface owns its own origin.
    mutating func beginTouch(at point: CGPoint) {
        guard touchOrigin == nil else { return }
        touchOrigin = point
    }

    /// SPEC §5.2 I: displacement from that touch's own origin becomes signed right-stick X.
    mutating func moveTouch(to point: CGPoint) {
        guard let origin = touchOrigin else { return }
        gamepad.rx = RacingMapper.axis(fromDrag: point.x - origin.x)
    }

    /// SPEC §5.2 I/L: `touchesEnded`/`touchesCancelled` clears RX only; every other field
    /// keeps whatever else is still held.
    mutating func endTouch() {
        guard touchOrigin != nil else { return }
        touchOrigin = nil
        gamepad.rx = 0
    }

    /// SPEC §5.2 J: press sets one ability bit, release clears that bit only.
    mutating func setButton(_ button: GamepadButtons, pressed: Bool) {
        if pressed { heldButtons.insert(button) } else { heldButtons.subtract(button) }
        gamepad.buttons = heldButtons
    }

    /// SPEC §5.2 J: brake is LT, gas is RT — two fields of the same report, so each pedal
    /// releases independently while the other keeps being held.
    mutating func setTrigger(_ trigger: GamepadTrigger, pressed: Bool) {
        switch trigger {
        case .brake: gamepad.lt = pressed ? 255 : 0
        case .gas: gamepad.rt = pressed ? 255 : 0
        }
    }

    /// SPEC §5.2 L: put every racing source back to neutral; the caller sends that neutral
    /// report as the newest state.
    mutating func neutralize() {
        touchOrigin = nil
        heldButtons = []
        gamepad = .zero
    }
}

#if os(iOS)
    /// Maps device-motion attitude increments to relative HID mouse movement
    /// (SPEC §5.1 B/C/E/G/H/K). Output reuses the existing relative-mouse report
    /// path (`HIDInput.move`): no new HID report type, no absolute digitizer, no
    /// smoothing, filtering, interpolation and no cadence coupling with touch.
    ///
    /// SPEC §5.2: `mode == .racing` reuses this same single device-motion pipeline
    /// (`CMMotionManager`, `.xArbitraryZVertical` — no second motion manager and no
    /// new dependency) but maps an *absolute* deflection from a RECENTER-established
    /// baseline into the gamepad report instead. The §5.1 incremental relative-mouse
    /// mapping is never reused for racing and the aim semantics above are unchanged.
    @MainActor
    final class GyroAimController: ObservableObject {
        /// `false` when device motion cannot be used: no gyro delta is produced and
        /// the GAME chrome shows an "unavailable" status (SPEC §5.1 H).
        @Published private(set) var isAvailable = false

        /// HID mouse counts per radian of device rotation (SPEC §5.1 C).
        var sensitivity: Double = AppSettings.defaultGyroSensitivity

        /// SPEC §5.2 G/H: which GAME input source this pipeline feeds. `racing` uses
        /// the absolute baseline mapping; `touch`/`gyro`/`hybrid` keep §5.1 exactly.
        var mode: GameInputMode = .touch

        private var hid: HIDInput = .unavailable
        private let manager = CMMotionManager()
        private var previous: RacingQuaternion?

        /// Fractional mouse counts left over from the previous sample. A 10 ms
        /// sample at the default 180 counts/radian needs ~0.32 deg of rotation for
        /// a single Int8 count, so sub-integer movement must be carried forward
        /// instead of truncated away (SPEC §5.1 C). This is plain accumulation of
        /// already-computed counts, not smoothing, filtering or interpolation.
        private var carryX: Double = 0
        private var carryY: Double = 0

        /// Start gyro input through `hid`. The current attitude becomes the baseline,
        /// so stale deltas are never replayed (SPEC §5.1 G).
        func start(_ hid: HIDInput) {
            // SPEC §5.2 H/J: bind the routing first. In RACING the pedals, the ability
            // buttons and the floating drag must keep working even when device motion
            // is unavailable; only steering needs motion, and steering never falls
            // back to keycodes or to the relative-mouse path.
            self.hid = hid
            guard manager.isDeviceMotionAvailable else {
                stop()
                return
            }
            previous = nil
            carryX = 0
            carryY = 0
            // SPEC §5.2 E: a fresh racing session starts from one neutral state.
            racing = RacingSourceState()
            isRunning = true
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                guard let motion = motion else { return }
                let attitude = motion.attitude.quaternion
                let sample = RacingQuaternion(
                    w: Double(attitude.w), x: Double(attitude.x),
                    y: Double(attitude.y), z: Double(attitude.z)
                )
                Task { @MainActor in
                    self?.handle(sample)
                }
            }
            isAvailable = true
        }

        /// Stop producing gyro deltas (touch stays the only GAME input source).
        func stop() {
            // SPEC §5.2 L: stop the motion source first, so no sample that is still in
            // flight can write a steering axis after the neutralizing report was sent.
            isRunning = false
            manager.stopDeviceMotionUpdates()
            previous = nil
            carryX = 0
            carryY = 0
            isAvailable = false
            // SPEC §5.2 L: leaving RACING, leaving GAME or losing the link must not
            // leave Windows holding a stick, pedal or button.
            neutralizeRacing()
        }

        /// Set the previous-attitude baseline to the current attitude; recentering
        /// itself emits no movement (SPEC §5.1 F). SPEC §5.2 H: the same re-baseline is
        /// the racing RECENTER affordance, so no spike is ever emitted, and a steering
        /// deflection that was already transmitted is cleared immediately by sending
        /// LX = 0 while every other held field keeps its value (both pedals, the
        /// floating drag, the ability buttons).
        func recenter() {
            previous = nil
            carryX = 0
            carryY = 0
            // SPEC §5.2 H: a steering deflection that was already transmitted must be
            // cleared immediately. The baseline stays absolute (`previous = nil` above, so
            // the next sample measures from the pose that was just recorded), and only
            // LX is written: RX, both pedals and the held ability buttons keep whatever
            // values the racing sources still hold.
            guard mode == .racing else { return }
            let held = racing.gamepad
            racing.gamepad.lx = 0
            guard racing.gamepad != held else { return }
            hid.sendGamepad(racing.gamepad)
        }

        // MARK: racing sources (SPEC §5.2 E/I/J/L)

        /// The one current racing state (SPEC §5.2 E: latest state wins, never a queue).
        /// Every racing source writes only its own field(s) and re-sends the whole report,
        /// so steering, both pedals, the floating drag and the ability buttons can all be
        /// held at the same time.
        private var racing = RacingSourceState()
        /// `false` while the motion source is stopped, so a sample that is still in flight
        /// cannot write a steering axis after racing has been left (SPEC §5.2 L).
        private var isRunning = false

        /// SPEC §5.2 I: a touch that begins on the free racing surface owns its own
        /// origin; only the first free touch drives right-stick X.
        func beginRacingTouch(at point: CGPoint) {
            racing.beginTouch(at: point)
        }

        /// Displacement from that touch's own origin, mapped to signed right-stick X.
        func moveRacingTouch(to point: CGPoint) {
            let held = racing.gamepad
            racing.moveTouch(to: point)
            guard racing.gamepad != held else { return }
            hid.sendGamepad(racing.gamepad)
        }

        /// SPEC §5.2 I/L: `touchesEnded`/`touchesCancelled` resets RX only; every other
        /// field keeps whatever else is still held.
        func endRacingTouch() {
            let held = racing.gamepad
            racing.endTouch()
            guard racing.gamepad != held else { return }
            hid.sendGamepad(racing.gamepad)
        }

        /// SPEC §5.2 J: momentary ability buttons — press sets one bit, release clears
        /// that bit only, and the release report is sent even when the earlier press
        /// was never acknowledged (latest state wins, §5.2 E).
        func setRacingButton(_ button: GamepadButtons, pressed: Bool) {
            let held = racing.gamepad
            racing.setButton(button, pressed: pressed)
            guard racing.gamepad != held else { return }
            hid.sendGamepad(racing.gamepad)
        }

        /// SPEC §5.2 J: gas is RT, brake is LT — two separate fields of the same
        /// report, so both can be present at once and each releases independently.
        func setRacingTrigger(_ trigger: GamepadTrigger, pressed: Bool) {
            let held = racing.gamepad
            racing.setTrigger(trigger, pressed: pressed)
            guard racing.gamepad != held else { return }
            hid.sendGamepad(racing.gamepad)
        }

        /// SPEC §5.2 L: put every racing source back to neutral and send that neutral
        /// report as the newest state (axes 0, triggers 0, all bits released). The
        /// accepted report updates the transport cache through `sendGamepad`.
        func neutralizeRacing() {
            let wasHolding = racing.gamepad != .zero
            racing.neutralize()
            guard wasHolding else { return }
            hid.sendGamepad(.zero)
        }

        private func handle(_ current: RacingQuaternion) {
            guard let p = previous else {
                previous = current
                carryX = 0
                carryY = 0
                return
            }
            if mode == .racing {
                // SPEC §5.2 L: while racing is being left (or the app resigns active) the
                // motion source is stopped before the neutral report is sent, so a sample
                // that is already in flight must not write LX again afterwards.
                guard isRunning else { return }
                // SPEC §5.2 H: RACING does not use the incremental §5.1 mapping and does
                // not use the mouse sensitivity. Steering is the signed rotation about the
                // device screen-normal, measured from the fixed baseline established on
                // racing activation / RECENTER, so `previous` is deliberately not updated
                // here: turning the iPad back to the recorded pose returns the stick to
                // centre and never drifts. Clockwise, as the user faces the screen, is a
                // positive left-stick X.
                let degrees = RacingMapper.screenNormalDegrees(from: p, to: current)
                let axis = RacingMapper.axis(fromAngle: degrees)
                guard racing.gamepad.lx != axis else { return }
                racing.gamepad.lx = axis
                hid.sendGamepad(racing.gamepad)
                return
            }
            // Incremental rotation from the previously used attitude: q_previous⁻¹ ⊗ q_current.
            let w = p.w * current.w + p.x * current.x + p.y * current.y + p.z * current.z
            let rx = p.w * current.x - p.x * current.w - p.y * current.z + p.z * current.y
            let ry = p.w * current.y - p.y * current.w + p.x * current.z - p.z * current.x
            let rz = p.w * current.z - p.z * current.w - p.x * current.y + p.y * current.x
            let norm = sqrt(rx * rx + ry * ry + rz * rz)
            guard norm > 1e-9 else { return }
            // Rotation vector (axis × angle) scaled by counts per radian: horizontal
            // rotation becomes positive dx, vertical rotation positive (down) dy (SPEC §5.1 E).
            let radians = 2.0 * atan2(norm, w) / norm
            previous = current
            let scale = radians * sensitivity
            // Add the counts left over from the previous sample before rounding to
            // Int8, so no computed movement is ever dropped.
            var dx = rx * scale + carryX
            var dy = ry * scale + carryY
            carryX = 0
            carryY = 0
            // MouseReport deltas are Int8: split a large rotation across consecutive
            // reports so a fast turn does not lose distance (same rule as touch).
            while abs(dx) > 127 || abs(dy) > 127 {
                let chunkX = dx > 0 ? min(127, dx) : max(-127, dx)
                let chunkY = dy > 0 ? min(127, dy) : max(-127, dy)
                let emitX = HIDInput.clamp(CGFloat(chunkX))
                let emitY = HIDInput.clamp(CGFloat(chunkY))
                hid.move(dx: emitX, dy: emitY)
                dx -= Double(emitX)
                dy -= Double(emitY)
            }
            // Send whole counts only; a sub-integer remainder stays in the carry.
            let wholeX = dx.rounded(.towardZero)
            let wholeY = dy.rounded(.towardZero)
            carryX = dx - wholeX
            carryY = dy - wholeY
            if wholeX != 0 || wholeY != 0 {
                hid.move(dx: HIDInput.clamp(CGFloat(wholeX)), dy: HIDInput.clamp(CGFloat(wholeY)))
            }
        }
    }
#endif
