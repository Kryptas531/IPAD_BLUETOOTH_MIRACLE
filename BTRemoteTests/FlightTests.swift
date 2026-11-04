import Foundation

@main
struct FlightTests {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ description: String) {
            checks += 1
            if !condition { fatalError("FLIGHT: \(description)") }
        }
        func q(_ x: Double, _ y: Double, _ z: Double, _ degrees: Double) -> RacingQuaternion {
            let half = degrees * Double.pi / 360
            return RacingQuaternion(w: cos(half), x: x * sin(half),
                                    y: y * sin(half), z: z * sin(half))
        }
        func multiply(_ a: RacingQuaternion, _ b: RacingQuaternion) -> RacingQuaternion {
            RacingQuaternion(w: a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
                             x: a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
                             y: a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
                             z: a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w)
        }
        expect(FlightConfiguration.privateIPv4("192.168.1.25"), "private receiver address")
        for host in ["0.0.0.0", "8.8.8.8", "::1", "010.0.0.1", "10.0.0", "example.com"] {
            expect(!FlightConfiguration.privateIPv4(host), "reject unsafe/ambiguous host")
        }
        expect(FlightConfiguration.keyData(String(repeating: "ab", count: 32))?.count == 32,
               "32-byte pairing key")
        for key in ["", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            expect(FlightConfiguration.keyData(key) == nil, "reject invalid pairing key")
        }
        let baseline = q(1, 0, 0, 0)
        let neutral = FlightMapper.axes(from: baseline, to: baseline, landscapeRight: false)
        expect(neutral.lx == 0 && neutral.ly == 0, "exact neutral")
        let cw = FlightMapper.axes(from: baseline, to: q(0, 0, 1, -32), landscapeRight: false)
        expect(cw.lx == 127 && cw.ly == 0, "clockwise roll full right")
        let ccw = FlightMapper.axes(from: baseline, to: q(0, 0, 1, 32), landscapeRight: false)
        expect(ccw.lx == -127 && ccw.ly == 0, "counter-clockwise roll full left")
        for degrees in [-2.0, -1, 0, 1, 2] {
            let axes = FlightMapper.axes(from: baseline, to: q(0, 1, 0, degrees), landscapeRight: false)
            expect(axes.lx == 0 && axes.ly == 0, "pitch deadzone")
        }
        let pitch = FlightMapper.axes(from: baseline, to: q(0, 1, 0, 25), landscapeRight: false)
        let flipped = FlightMapper.axes(from: baseline, to: q(0, 1, 0, 25), landscapeRight: true)
        expect(pitch.lx == 0 && pitch.ly == 127, "landscape pitch full scale")
        expect(flipped.ly == -127, "opposite landscape pitch correction")
        let yaw = FlightMapper.axes(from: baseline, to: q(1, 0, 0, 20), landscapeRight: false)
        expect(yaw.lx == 0 && yaw.ly == 0, "out-of-plane yaw does not steer")
        let held = q(1, 0, 0, 60)
        let heldRoll = FlightMapper.axes(from: held, to: multiply(held, q(0, 0, 1, -32)),
                                         landscapeRight: false)
        expect(heldRoll.lx == 127 && heldRoll.ly == 0, "roll from arbitrary held baseline")
        let same = FlightMapper.axes(from: held, to: held, landscapeRight: false)
        expect(same.lx == 0 && same.ly == 0, "return to held baseline")
        let neg = RacingQuaternion(w: -held.w, x: -held.x, y: -held.y, z: -held.z)
        let equivalent = FlightMapper.axes(from: held, to: neg, landscapeRight: false)
        expect(equivalent.lx == 0 && equivalent.ly == 0, "q and -q are equivalent")
        let invalid = RacingQuaternion(w: .nan, x: 0, y: 0, z: 0)
        let invalidAxes = FlightMapper.axes(from: baseline, to: invalid, landscapeRight: false)
        expect(invalidAxes.lx == 0 && invalidAxes.ly == 0, "nonfinite samples neutral")
        var state = FlightState(buttons: 0xa5, lx: -127, ly: 127, rx: -1, ry: 1, lt: 255, rt: 128)
        let uuid = UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")!
        let bytes = state.payload(session: uuid, sequence: 0x0102030405060708)
        expect(bytes.count == 36, "unsigned payload is exactly 36 bytes")
        expect(bytes.map { String(format: "%02x", $0) }.joined() ==
               "49475031000102030405060708090a0b0c0d0e0f010203040506070800a5817fff01ff80",
               "byte-exact cross-language signed axes, button order, sequence")
        state.recenter()
        expect(state.lx == 0 && state.ly == 0, "RECENTER clears both flight axes")
        expect(state.buttons == 0xa5 && state.lt == 255 && state.rt == 128 &&
               state.rx == -1 && state.ry == 1, "RECENTER preserves all independent held fields")
        state.setButton(2, pressed: true)
        state.setButton(1, pressed: false)
        expect(state.buttons == 0xa6, "independent momentary button release")
        state = .zero
        expect(state.payload(session: uuid, sequence: 1).suffix(8) == Data(repeating: 0, count: 8),
               "neutral report clears all controls")
        let heldInput = FlightState(buttons: 3, lx: 127, ly: -127,
                                    rx: 50, ry: -50, lt: 255, rt: 255)
        var oldStream = FlightStream()
        _ = oldStream.next(heldInput)
        var rearmed = FlightStream()
        expect(rearmed.session != oldStream.session, "re-arm creates fresh random session")
        for frame in 1...30 {
            let packet = rearmed.next(heldInput)
            expect(packet.suffix(8) == Data(repeating: 0, count: 8),
                   "re-arm handshake stays neutral despite held inputs")
            expect(rearmed.sequence == UInt64(frame), "neutral handshake sequence advances")
        }
        expect(rearmed.next(heldInput).suffix(8) == heldInput.payload(
            session: rearmed.session, sequence: 31).suffix(8),
               "new input follows neutral takeover interval")
        var gate = FlightReleaseGate()
        gate.rearm(held: heldInput, dragging: true)
        expect(!gate.button(1, pressed: true), "held A cannot replay after re-arm")
        expect(!gate.button(2, pressed: true), "held B independently blocked")
        expect(gate.button(4, pressed: true), "new unrelated X press accepted")
        expect(gate.button(1, pressed: false) && gate.button(1, pressed: true),
               "release then new A press re-arms only A")
        expect(!gate.button(2, pressed: true), "B still requires its own release")
        expect(!gate.trigger(right: true, pressed: true) &&
               !gate.trigger(right: false, pressed: true), "both held triggers blocked")
        expect(gate.trigger(right: true, pressed: false) &&
               gate.trigger(right: true, pressed: true), "RT release then press accepted")
        expect(!gate.trigger(right: false, pressed: true), "LT independently blocked")
        expect(gate.camera, "old camera gesture blocked")
        gate.rearm(held: .zero, dragging: false)
        expect(gate.camera && !gate.button(2, pressed: true),
               "repeated re-arm cannot clear pending release gates")
        gate.endCamera()
        expect(!gate.camera, "camera end permits a new gesture")
        print("FLIGHT: \(checks) checks passed")
    }
}
