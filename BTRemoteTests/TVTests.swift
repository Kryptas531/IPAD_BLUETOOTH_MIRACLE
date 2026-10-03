import Foundation
import CryptoKit

private enum TVTestError: Error { case failed(String) }

@MainActor
private final class MemoryLibraryPersistence: TVLibraryPersistence {
    var data: Data?
    var failRead = false
    var failWrite = false
    var writes = 0
    func read() throws -> Data? {
        if failRead { throw TVTestError.failed("synthetic read failure") }
        return data
    }
    func write(_ value: Data) throws {
        if failWrite { throw TVTestError.failed("synthetic write failure") }
        data = value; writes += 1
    }
}

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

    static func main() async throws {
        let callbackReturned = await TVRemoteClient.runNoNetworkCallbackCheck()
        try expect(callbackReturned, "Production network callback runs off-main and returns to MainActor without a runtime trap")
        #if os(macOS)
        if let value = ProcessInfo.processInfo.environment["TV_TLS_PROBE_PORT"], let port = UInt16(value), port != 0 {
            let tls = await TVRemoteClient.runLoopbackTLSCallbackCheck(port: port)
            try expect(tls.candidate, "Production Security callback accepts pairing candidate on real background TLS queue without crashing")
            try expect(tls.pinned, "Real TLS callback accepts exact saved certificate")
            try expect(tls.mismatch, "Real TLS callback rejects changed certificate without relaxing pinning")
        }
        #endif
        try libraryChecks()
        for address in ["10.0.0.2", "172.16.0.2", "172.31.255.254", "192.168.1.5", "fd00::2", "fe80::2"] {
            try expect(TVRemoteClient.privateAddress(address), "Private TV address accepted")
        }
        for address in ["8.8.8.8", "127.0.0.1", "172.32.0.1", "224.0.0.1", "::1", "2001:4860::8888", "192.168.1.2:6466", "tv.local", " 10.0.0.2"] {
            try expect(!TVRemoteClient.privateAddress(address), "Public, loopback, named or custom-port address rejected")
        }
        // Reference bytes from polo.proto/remotemessage.proto at SPEC 784bad0's pinned revision.
        let request = TVWire.encodedPolo(.pairingRequest(serviceName: "atvremote", clientName: "BTRemote"))
        try expect(request == hex("1c080210c80152150a0961747672656d6f74651208425452656d6f7465"), "Polo request bytes")
        let secret = Data(repeating: 0xaa, count: 32)
        try expect(TVWire.encodedPolo(.secret(secret)) == hex("2a080210c801c202220a20") + secret, "Polo nested secret and long tag")
        let ack = hex("080210c801ca02220a20") + secret
        try expect(TVWire.decodePolo(ack) == .secretAck(secret), "Polo nested secret acknowledgement")
        if case .rejected = TVWire.decodePolo(hex("fa0100")) { checks += 1 }
        else { throw TVTestError.failed("Polo acknowledgement without status accepted") }
        if case .rejected = TVWire.decodePolo(hex("080110c8015a00")) { checks += 1 }
        else { throw TVTestError.failed("Different Polo protocol version accepted") }

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
        print("TV TESTS PASSED: \(checks) checks; wire/library/persistence/session/certificate checks, hardware pending.")
    }

    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try expect(rejected, message)
    }

    static func libraryChecks() throws {
        try expect(TVFeature.requested.contains(.appLink), "APP_LINK512 requested")
        try expect(TVRemoteWire.encoded(.appLink("https://x")) == hex("0ed2050b0a0968747470733a2f2f78"), "Independent field90 nested field1 fixture")
        let target = try TVLaunchTarget.parse("org.xbmc.kodi", kind: .app)
        try expect(target.wireLink == "market://launch?id=org.xbmc.kodi" && target.expectedPackage == "org.xbmc.kodi", "Package conversion uses author launch URI")
        for bad in ["", "org..kodi", "org.1kodi", "org.kodi&id=evil", "//example.com", "example.com/path", "javascript:alert(1)", "data:text/html,x", "file:///tmp/x", "content://x", "intent://x", "https://", "https://bad host/x", "https://x/\nsecret", String(repeating: "a", count: 8193)] {
            try rejects({ _ = try TVLaunchTarget.parse(bad, kind: .app) }, "Invalid/unsafe/oversized target rejected")
        }
        try rejects({ _ = try TVLaunchTarget.parse("org.xbmc.kodi", kind: .bookmark) }, "Bookmark requires URI")
        let query = "Привет & # /😀"
        let search = try TVLaunchTarget.youtubeSearch(query)
        let components = URLComponents(string: search.wireLink)!
        try expect(components.host == "www.youtube.com" && components.path == "/results", "YouTube search destination")
        try expect(components.queryItems == [URLQueryItem(name: "search_query", value: query)] && components.fragment == nil, "Unicode search cannot inject query or fragment")
        let unicode = try TVLaunchTarget.parse("https://example.com/привет?q=a%26b#chapter", kind: .bookmark)
        let decoded = URLComponents(string: unicode.wireLink)!
        try expect(decoded.path == "/привет" && decoded.queryItems?.first?.value == "a&b" && decoded.fragment == "chapter", "Unicode link preserves query and fragment")
        try rejects({ _ = try TVLaunchTarget.youtubeSearch(" ") }, "Empty search rejected")
        try rejects({ _ = try TVLaunchTarget.youtubeSearch(String(repeating: "a", count: 513)) }, "Oversized search rejected")

        var session = TVSession()
        let initialGeneration = session.generation
        try expect(session.launchFrame(target, expectedGeneration: initialGeneration) == nil, "Disconnected launch blocked")
        session.beginConnect()
        _ = session.noteRemoteConfigure(supported: [.ping, .key], deviceInfo: nil)
        session.markConnected()
        try expect(session.launchFrame(target, expectedGeneration: session.generation) == nil && session.tapKey(.dpadUp) != nil, "Missing app feature blocks launch while remote works")
        session.beginConnect()
        _ = session.noteRemoteConfigure(supported: .requested, deviceInfo: nil)
        try expect(session.launchFrame(target, expectedGeneration: session.generation) == nil, "Handshake cannot launch")
        session.markConnected()
        let connectedGeneration = session.generation
        try expect(session.launchFrame(target, expectedGeneration: connectedGeneration) == .appLink(target.wireLink), "Negotiated connected launch")
        try expect(session.launchFrame(target, expectedGeneration: initialGeneration) == nil, "Stale generation launch rejected")
        session.noteCurrentApp("org.xbmc.kodi")
        try expect(session.currentApp == "org.xbmc.kodi" && !session.textEntryAvailable, "Current app metadata does not authorize IME")
        session.noteCurrentApp("https://example.com")
        try expect(session.currentApp == nil, "Invalid package metadata cleared")
        session.noteCurrentApp("org.xbmc.kodi")
        session.beginReconnect()
        try expect(session.currentApp == nil && !session.appLaunchAvailable && session.launchFrame(target, expectedGeneration: connectedGeneration) == nil, "Reconnect clears current app and rejects old launch without replay")
        for (key, code) in [(TVKeycode.mediaStop, 86), (.mediaNext, 87), (.mediaPrevious, 88), (.mediaRewind, 89), (.mediaFastForward, 90)] {
            try expect(key.rawValue == Int32(code), "Media key matches pinned Android enum")
        }

        var library = try TVLibrary.initial.validated()
        try expect(library.items.count == 2 && library.items.allSatisfy { $0.kind == .app }, "Apps surface has initial launch tiles")
        try expect(TVLibrary.catalog.count == 6 && Set(TVLibrary.catalog.map(\.id)).count == 6, "Editable catalog has stable distinct IDs")
        var bookmark = TVLibraryItem(title: " Playlist ", kind: .bookmark, target: "https://example.com/list", symbol: "bookmark")
        try library.upsert(bookmark)
        try expect(library.items.last?.title == "Playlist", "Title trimmed on save")
        bookmark.title = "Updated"; try library.upsert(bookmark)
        try expect(library.items.count == 3 && library.items.last?.title == "Updated", "Edit retains identity without duplicate")
        library.toggleFavorite(bookmark.id)
        try expect(library.items.last?.favorite == true, "Favorite survives item edit")
        library.move(bookmark.id, by: Int.min)
        try expect(library.items.first?.id == bookmark.id, "Extreme negative move clamps without overflow")
        library.move(bookmark.id, by: Int.max)
        try expect(library.items.last?.id == bookmark.id, "Extreme positive move clamps without overflow")
        library.recordLaunch(bookmark.id); library.recordLaunch(bookmark.id)
        try expect(library.recentIDs == [bookmark.id], "Recent launches deduplicated")
        library.remove(bookmark.id)
        try expect(!library.items.contains { $0.id == bookmark.id } && library.recentIDs.isEmpty, "Deletion clears recents")
        for index in 0..<62 {
            let item = TVLibraryItem(title: "Item \(index)", kind: .bookmark, target: "https://example.com/\(index)")
            try library.upsert(item); library.recordLaunch(item.id)
        }
        try expect(library.items.count == 64 && library.recentIDs.count == 10 && library.recentItems.first?.title == "Item 61", "Library and recent limits with newest first")
        let before = library
        try rejects({ try library.upsert(bookmark) }, "65th item rejected")
        try expect(library == before, "Rejected mutation leaves library unchanged")
        let restored = try JSONDecoder().decode(TVLibrary.self, from: JSONEncoder().encode(library)).validated()
        try expect(restored == library, "Library JSON roundtrip preserves order/favorites/recents")
        var unknown = library; unknown.version = 2
        try rejects({ _ = try unknown.validated() }, "Unknown schema rejected")
        try rejects({ _ = try TVLibrary(items: [bookmark, bookmark]).validated() }, "Duplicate IDs rejected")
        try rejects({ _ = try TVLibrary(items: [bookmark], recentIDs: [bookmark.id, bookmark.id]).validated() }, "Duplicate recents rejected")
        try rejects({ _ = try TVLibrary(items: [bookmark], recentIDs: [UUID()]).validated() }, "Dangling recent rejected")
        for title in ["", "\nsecret", String(repeating: "a", count: 81)] {
            var invalid = bookmark; invalid.title = title
            try rejects({ try library.upsert(invalid) }, "Invalid title rejected")
        }

        let persistence = MemoryLibraryPersistence()
        let store = TVLibraryStore(persistence: persistence)
        try expect(store.isReady && store.library == TVLibrary.initial && persistence.writes == 0, "Missing record seeds without writing")
        try expect(store.upsert(bookmark) && persistence.writes == 1, "Actual store saves candidate before publishing")
        let snapshot = store.library
        persistence.failWrite = true
        try expect(!store.remove(bookmark.id) && store.library == snapshot && store.errorMessage != nil, "Write failure preserves published and saved library")
        persistence.failWrite = false; persistence.failRead = true
        store.reload()
        try expect(!store.isReady && store.library == snapshot && !store.remove(bookmark.id), "Read failure preserves library and blocks editing")
        persistence.failRead = false; store.reload()
        try expect(store.isReady && store.library == snapshot, "Retry restores persisted record")
        persistence.data = Data("corrupt".utf8)
        let corrupt = TVLibraryStore(persistence: persistence)
        try expect(!corrupt.isReady && corrupt.library.items.isEmpty && persistence.data == Data("corrupt".utf8), "Corrupt record not overwritten with defaults")
        persistence.data = try JSONEncoder().encode(unknown)
        let future = TVLibraryStore(persistence: persistence)
        try expect(!future.isReady && persistence.writes == 1, "Unknown persisted schema not replaced")
    }
}
