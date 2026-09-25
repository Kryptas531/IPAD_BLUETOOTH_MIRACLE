import Foundation
import SwiftUI
#if os(iOS)
    import CoreMotion
#endif

/// GAME input source (SPEC §5.1 A/I). Touch stays the default; gyro and hybrid
/// are only reachable from the temporary GAME chrome.
enum GameInputMode: String {
    case touch
    case gyro
    case hybrid
}

#if os(iOS)
    /// One device attitude sample (quaternion), used to derive attitude increments.
    private struct Attitude: Sendable {
        var w: Double
        var x: Double
        var y: Double
        var z: Double
    }

    /// Maps device-motion attitude increments to relative HID mouse movement
    /// (SPEC §5.1 B/C/E/G/H/K). Output reuses the existing relative-mouse report
    /// path (`HIDInput.move`): no new HID report type, no absolute digitizer, no
    /// smoothing, filtering, interpolation and no cadence coupling with touch.
    @MainActor
    final class GyroAimController: ObservableObject {
        /// `false` when device motion cannot be used: no gyro delta is produced and
        /// the GAME chrome shows an "unavailable" status (SPEC §5.1 H).
        @Published private(set) var isAvailable = false

        /// HID mouse counts per radian of device rotation (SPEC §5.1 C).
        var sensitivity: Double = AppSettings.defaultGyroSensitivity

        private var hid: HIDInput = .unavailable
        private let manager = CMMotionManager()
        private var previous: Attitude?

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
            guard manager.isDeviceMotionAvailable else {
                stop()
                return
            }
            self.hid = hid
            previous = nil
            carryX = 0
            carryY = 0
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                guard let motion = motion else { return }
                let attitude = motion.attitude.quaternion
                let sample = Attitude(
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
            manager.stopDeviceMotionUpdates()
            previous = nil
            carryX = 0
            carryY = 0
            isAvailable = false
        }

        /// Set the previous-attitude baseline to the current attitude; recentering
        /// itself emits no movement (SPEC §5.1 F).
        func recenter() {
            previous = nil
            carryX = 0
            carryY = 0
        }

        private func handle(_ current: Attitude) {
            guard let p = previous else {
                previous = current
                carryX = 0
                carryY = 0
                return
            }
            // Incremental rotation from the previously used attitude: q_previous⁻¹ ⊗ q_current.
            let w = p.w * current.w + p.x * current.x + p.y * current.y + p.z * current.z
            let rx = p.w * current.x - p.x * current.w - p.y * current.z + p.z * current.y
            let ry = p.w * current.y - p.y * current.w + p.x * current.z - p.z * current.x
            let rz = p.w * current.z - p.z * current.w - p.x * current.y + p.y * current.x
            previous = current
            let norm = sqrt(rx * rx + ry * ry + rz * rz)
            guard norm > 1e-9 else { return }
            // Rotation vector (axis × angle) scaled by counts per radian: horizontal
            // rotation becomes positive dx, vertical rotation positive (down) dy (SPEC §5.1 E).
            let scale = (2.0 * atan2(norm, w) / norm) * sensitivity
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
                hid.move(dx: HIDInput.clamp(CGFloat(chunkX)), dy: HIDInput.clamp(CGFloat(chunkY)))
                dx -= chunkX
                dy -= chunkY
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
