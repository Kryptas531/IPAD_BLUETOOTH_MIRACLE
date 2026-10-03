import Foundation
import CryptoKit

private enum TVTestError: Error { case failed(String) }

@main
@MainActor
struct TVTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TVTestError.failed(message) }
        checks += 1
    }

    static func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }

    static func main() throws {
        // Reference bytes from polo.proto/remotemessage.proto at SPEC 784bad0's pinned revision.
        let request = TVWire.encodedPolo(.pairingRequest(serviceName: "atvremote", clientName: "BTRemote"))
        try expect(request == hex("1c080210c80152150a0961747672656d6f74651208425452656d6f7465"), "Polo request bytes")
        let secret = Data(repeating: 0xaa, count: 32)
        try expect(TVWire.encodedPolo(.secret(secret)) == hex("2a080210c801c202220a20") + secret, "Polo nested secret and long tag")
        let ack = hex("080210c801ca02220a20") + secret
        try expect(TVWire.decodePolo(ack) == .secretAck(secret), "Polo nested secret acknowledgement")
        if case .rejected = TVWire.decodePolo(hex("fa0100")) { checks += 1 }
        else { throw TVTestError.failed("Polo acknowledgement without status accepted") }

        let up = TVRemoteWire.encoded(.key(.dpadUp, direction: .short))
        try expect(up == hex("06520408131003"), "Reference DPAD short packet")
        try expect(TVRemoteWire.decode(hex("c20200")) == .start(started: false), "Proto3 omitted bool is off")
        try expect(TVRemoteWire.decode(hex("c202020801")) == .start(started: true), "Observed on")
        try expect(TVRemoteWire.decode(hex("4200")) == .pingRequest(val1: 0, val2: 0), "Proto3 ping defaults")
        try expect(TVRemoteWire.decode(hex("aa0100")) == .imeBatchEdit(imeCounter: 0, fieldCounter: 0), "Proto3 IME defaults")
        try expect(TVProtobuf.decode(hex("120201")) == nil, "Truncated length-delimited field")
        try expect(TVProtobuf.decodeVarint(Array(repeating: 0xff, count: 9) + [2], offset: 0) == nil, "64-bit varint overflow")
        try expect(TVProtobuf.decodeVarint(Array(repeating: 0xff, count: 9) + [1], offset: 0)?.value == UInt64.max, "64-bit varint maximum")
        try expect(TVProtobuf.decodeVarint([0x80], offset: 0) == nil, "Truncated varint")
        let fixed = [TVWireField(number: 100, value: .fixed32(Data([1, 2, 3, 4]))),
                     TVWireField(number: 101, value: .fixed64(Data(repeating: 5, count: 8)))]
        try expect(TVProtobuf.decode(TVProtobuf.encode(fixed)) == fixed, "Unknown fixed fields survive")

        var reader = TVFrameReader()
        for byte in up.dropLast() { try expect(reader.feed(Data([byte])).isEmpty, "Partial frame does not emit") }
        try expect(reader.feed(Data(up.suffix(1))) == [hex("520408131003")], "Split frame completes once")
        try expect(reader.feed(up + hex("03c20200")).count == 2, "Coalesced frames")
        try expect(reader.pendingByteCount == 0, "No buffered complete frame")
        _ = reader.feed(TVProtobuf.encodeVarint(UInt64(TVLimits.maxMessageBytes + 1)))
        try expect(reader.failure != nil, "Oversized frame rejected")
        try expect(reader.feed(up).isEmpty, "Corrupt stream remains rejected")
        reader.reset()
        try expect(reader.feed(up).count == 1, "New session discards framing failure")
        _ = reader.feed(Data(repeating: 0xff, count: 10))
        try expect(reader.failure == .varintOverflow, "Corrupt frame varint rejected")

        // Independent Node SHA-256 oracle recorded by the orchestrator, synthetic public inputs.
        let client = TVWire.TVRSAKeyMaterial(modulus: hex("810203"), exponent: hex("010001"))
        let server = TVWire.TVRSAKeyMaterial(modulus: hex("910405"), exponent: hex("010001"))
        let digest = hex("84f12cb01e89d2f4244ae853de0c53379acbb037fa290acae56eb5debd067bce")
        try expect(TVWire.pairingSecret(clientKey: client, serverKey: server, code: "84abcd") == digest, "Pairing hash byte order and odd-length exponent")
        try expect(TVWire.pairingSecret(clientKey: client, serverKey: server, code: "00abcd") == nil, "Wrong pairing code")
        try expect(TVWire.pairingSecret(clientKey: client, serverKey: server, code: "84zzzz") == nil, "Non-hex pairing code")

        let gate = RemoteTargetSession()
        var releases = HIDSessionReleaseQueue()
        releases.replace([(1, Data([0])), (2, Data([0, 0]))])
        try expect(releases.next?.id == 1, "First neutral release queued")
        try expect(releases.next?.id == 1, "Backpressure retains unaccepted release")
        releases.accepted()
        try expect(releases.next?.id == 2, "Other neutral reports cannot overwrite release")
        releases.replace([(3, Data([0]))])
        try expect(releases.next?.id == 3, "New teardown replaces prior neutral queue")
        releases.clear()
        try expect(releases.next == nil, "Radio reset clears release queue")
        let pc = gate.token
        try expect(gate.accepts(pc), "Initial PC session")
        gate.transition(to: .tv)
        try expect(!gate.accepts(pc), "PC callback discarded on TV switch")
        gate.transition(to: .pc)
        try expect(!gate.accepts(pc), "Old PC callback discarded after PC-TV-PC")
        let freshPC = gate.token
        gate.suspend()
        try expect(!gate.accepts(freshPC) && !gate.accepts(gate.token), "Inactive session cannot send")
        gate.resume()
        try expect(!gate.accepts(freshPC) && gate.accepts(gate.token), "Foreground starts new session")

        var session = TVSession()
        session.beginConnect()
        _ = session.noteRemoteConfigure(supported: .requested, deviceInfo: nil)
        try expect(session.notePingRequest(val1: 7, val2: 0) == .pingResponse(val1: 7), "Handshake ping answered")
        session.markConnected()
        session.noteIMEBatchEdit(imeCounter: 2, fieldCounter: 3)
        try expect(!session.textEntryAvailable, "Counters alone do not authorize text")
        session.noteIMEField(counter: 3, active: true, supported: true)
        session.noteIMEBatchEdit(imeCounter: 2, fieldCounter: 3)
        try expect(session.textEntryAvailable, "Active supported matching IME field")
        let unicode = "Привет 😀"
        guard let textFrame = session.textFrame(unicode) else { throw TVTestError.failed("Unicode text frame unavailable") }
        let raw = TVProtobuf.decode(TVRemoteWire.encoded(textFrame).dropFirst())!
        let batch = TVProtobuf.nested(raw, 21)!
        let edit = TVProtobuf.nested(batch, 3)!
        let field = TVProtobuf.nested(edit, 2)!
        try expect(TVProtobuf.data(field, 3) == Data(unicode.utf8), "Unicode payload retained")
        try expect(TVProtobuf.varint(batch, 1) == 2 && TVProtobuf.varint(batch, 2) == 3, "Current IME counters encoded")
        session.noteIMEField(counter: 4, active: true, supported: true)
        try expect(session.textFrame(unicode) == nil, "Changed field discards old IME counters")
        session.noteIMEBatchEdit(imeCounter: 2, fieldCounter: 3)
        try expect(!session.textEntryAvailable, "Stale field update rejected")
        session.noteIMEField(counter: 4, active: true, supported: false)
        try expect(!session.textEntryAvailable, "Unsupported field unavailable")
        try expect(session.pressKey(.dpadUp) != nil, "Long press starts")
        try expect(session.pressKey(.dpadUp) == nil, "Duplicate held press suppressed")
        try expect(session.releaseAllHeldKeys() == [.key(.dpadUp, direction: .endLong)], "Held input released")
        try expect(session.requestPowerToggle() != nil && session.pendingPower && session.power == .unknown, "Power send remains pending")
        session.noteRemoteStart(started: true)
        try expect(!session.pendingPower && session.power == .on, "Observed power resolves request")
        _ = session.requestPowerToggle()
        session.expirePendingPower()
        try expect(session.power == .unknown && !session.pendingPower, "Power timeout is unknown")
        _ = session.pressKey(.volumeUp)
        let generation = session.generation
        session.markUnavailable("test reachability loss")
        try expect(!session.belongs(to: generation) && session.heldKeys.isEmpty && session.power == .unknown, "Loss invalidates session and clears held state")
        session.beginReconnect()
        try expect(session.textFrame(unicode) == nil && session.tapKey(.power) == nil && session.heldKeys.isEmpty, "Reconnect never replays commands")

        let certificate = try TVIdentityStore.runNoNetworkSelfCheck()
        try expect(certificate.signatureVerified && certificate.publicKeyVerified && certificate.pairingVectorVerified, "Actual RSA X509 generator and signature")
        try expect(!certificate.identityVerified, "No false claim of iPad Keychain verification")
        let binding = TVSavedPairing(host: "192.168.0.2", label: "Test TV", serverCertificateSHA256: Data(SHA256.hash(data: secret)))
        try TVIdentityStore.verifyPeerCertificate(secret, pairing: binding)
        var rejected = false
        do { try TVIdentityStore.verifyPeerCertificate(Data([1]), pairing: binding) }
        catch TVIdentityError.rePairRequired { rejected = true }
        try expect(rejected, "Changed TV certificate requires explicit re-pair")
        let saved = try JSONDecoder().decode(TVSavedPairing.self, from: JSONEncoder().encode(binding))
        try expect(saved == binding, "Saved TV binding serialization")
        print("TV TESTS PASSED: \(checks) checks; wire/session/certificate checks, hardware pending.")
    }
}
