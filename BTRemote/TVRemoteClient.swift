import Foundation
import Combine
import CryptoKit
@preconcurrency import Network
@preconcurrency import Security

/// The only shared TLS callback state. Security callbacks run on the network queue;
/// all connection/session/UI state remains on the main actor.
private final class TVPeerCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var certificate: Data?
    private var rejected = false
    func record(_ data: Data?, rejected: Bool) {
        lock.lock(); defer { lock.unlock() }
        certificate = data; self.rejected = rejected
    }
    func snapshot() -> (Data?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (certificate, rejected)
    }
}

/// SPEC 784bad0 §7.3: direct foreground-only Android TV Remote v2, no HID fallback.
@MainActor
final class TVRemoteClient: ObservableObject {
    @Published private(set) var state: TVConnectionState = .fresh
    @Published private(set) var power: TVPowerState = .unknown
    @Published private(set) var powerPending = false
    @Published private(set) var isPaired = false
    @Published private(set) var isAwaitingCode = false
    @Published private(set) var host = ""
    @Published private(set) var deviceLabel = "TV"
    @Published private(set) var lastError: String?
    @Published private(set) var sessionGeneration: UInt64 = 0
    @Published private(set) var currentApp: String?
    @Published private(set) var launchFeedback: String?
    private var session = TVSession()
    private var pairing: TVSavedPairing?
    private var identity: TVIdentityMaterial?
    private var connection: NWConnection?
    private var reader = TVFrameReader()
    private let queue = DispatchQueue(label: "BTRemote.TV.network")
    private var peer = TVPeerCheck()
    private enum PairStep { case request, options, configuration, code, secret }
    private var pairStep: PairStep?
    private var deadline: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var powerDeadline: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathAvailable = false
    private var pathObserved = false
    private var active = true
    private var requested = false
    private var retries = 0
    private var configured = false

    init() {
        // Reading credentials is local; no network connection or permission prompt on launch.
        do {
            pairing = try TVIdentityStore.loadPairing()
            if let pairing { host = pairing.host; deviceLabel = pairing.label; isPaired = true }
        } catch { lastError = "TV credentials cannot be read. Retry or explicitly forget and pair again." }
    }

    var canSendKeys: Bool { active && state == .connected && session.activeFeatures.contains(.key) }
    var textEntryAvailable: Bool { active && session.textEntryAvailable }
    var textFieldCounter: Int32? { session.activeFieldCounter }
    var canRequestPower: Bool { canSendKeys && session.activeFeatures.contains(.power) && !powerPending }
    var canLaunchApps: Bool { active && session.appLaunchAvailable }

    /// A successful return means queued on this connection, not that TV opened the content.
    @discardableResult
    func launch(_ target: TVLaunchTarget, expectedGeneration: UInt64) -> Bool {
        guard active, connection != nil, sessionGeneration == expectedGeneration,
              let frame = session.launchFrame(target, expectedGeneration: session.generation) else { return false }
        send(frame)
        launchFeedback = "Command sent to TV. Check the TV screen."
        return true
    }

    func beginPairing(host: String, label: String) {
        guard active else { return }
        guard pairing == nil else { fail("Forget the saved TV explicitly before pairing another identity.", retry: false); return }
        guard Self.privateAddress(host) else { fail("Enter a private numeric LAN address, without a port.", retry: false); return }
        requested = true; retries = 0
        self.host = host; deviceLabel = label.isEmpty ? "TV" : label
        open(pairingChannel: true, reconnecting: false)
    }

    func submitPairingCode(_ code: String) {
        guard active, pairStep == .code, isAwaitingCode, let identity,
              let certificate = peer.snapshot().0 else { return }
        do {
            let server = try TVIdentityStore.extractRSAModulusAndExponent(fromServerCertificate: certificate)
            let secret = try TVIdentityStore.pairingSecret(code: code, client: identity.clientPublicKey, server: server)
            pairStep = .secret; isAwaitingCode = false; lastError = nil
            send(TVWire.encodedPolo(.secret(secret)))
            armDeadline(seconds: 30, reason: "The TV did not confirm pairing. Retry pairing.")
        } catch { lastError = "The six hexadecimal characters do not match this TV. Check the displayed code." }
    }

    func connect(host: String) {
        guard active else { return }
        guard pairing != nil else { fail("Pair with the TV first.", retry: false); return }
        guard Self.privateAddress(host) else { fail("Enter a private numeric LAN address, without a port.", retry: false); return }
        requested = true; retries = 0; self.host = host
        open(pairingChannel: false, reconnecting: false)
    }

    func retry() {
        guard active else { return }
        if pairing != nil { connect(host: host) }
        else { beginPairing(host: host, label: deviceLabel) }
    }

    func disconnect() {
        requested = false; reconnect?.cancel(); reconnect = nil
        pathMonitor?.cancel(); pathMonitor = nil
        closeOldConnection(); session = TVSession(); publish()
    }

    func forgetPairing() {
        disconnect()
        do {
            try TVIdentityStore.forgetPairing()
            pairing = nil; identity = nil; isPaired = false; lastError = nil
        } catch { fail("TV credentials could not be removed. Unlock the iPad and retry.", retry: false) }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            reconnect?.cancel(); reconnect = nil
            pathMonitor?.cancel(); pathMonitor = nil
            closeOldConnection(); session = TVSession(); publish()
        } else if requested, pairing != nil {
            retries = 0; open(pairingChannel: false, reconnecting: true)
        }
    }

    func press(_ key: TVKeycode) { if canSendKeys, let frame = session.pressKey(key) { send(frame); publish() } }
    func release(_ key: TVKeycode) { if let frame = session.releaseKey(key) { send(frame); publish() } }
    func tap(_ key: TVKeycode) { if canSendKeys, let frame = session.tapKey(key) { send(frame) } }
    func sendText(_ text: String) { if active, let frame = session.textFrame(text) { send(frame) } }
    func releaseAllKeys() { for frame in session.releaseAllHeldKeys() { send(frame) }; publish() }
    func requestPowerToggle() {
        guard active, let frame = session.requestPowerToggle() else { return }
        send(frame); publish()
        let generation = sessionGeneration
        powerDeadline?.cancel()
        powerDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.sessionGeneration == generation else { return }
            self.session.expirePendingPower(); self.publish()
            self.lastError = "Power request was not confirmed by the TV. Its power state is unknown."
        }
    }

    private func open(pairingChannel: Bool, reconnecting: Bool) {
        closeOldConnection(); lastError = nil; configured = false
        if pairingChannel { session.beginPairing(); pairStep = .request }
        else if reconnecting { session.beginReconnect() } else { session.beginConnect() }
        publish()
        do {
            let material = try TVIdentityStore.loadOrCreate(); identity = material
            let tls = NWProtocolTLS.Options()
            guard let localIdentity = sec_identity_create(material.identity) else { throw TVIdentityError.rePairRequired }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let check = TVPeerCheck(); peer = check
            let saved = pairing
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions,
                Self.makePeerVerifier(pairingChannel: pairingChannel, saved: saved, check: check), queue)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let port = NWEndpoint.Port(rawValue: pairingChannel ? 6467 : 6466)!
            let socket = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            connection = socket
            let generation = sessionGeneration
            socket.stateUpdateHandler = { @Sendable [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.matches(socket, generation) else { return }
                    switch status {
                    case .ready:
                        if check.snapshot().1 { self.fail("The TV identity changed. Explicitly forget and pair again.", retry: false); return }
                        if pairingChannel {
                            self.send(TVWire.encodedPolo(.pairingRequest(serviceName: TVProtocol.serviceName, clientName: TVProtocol.clientName)))
                        }
                        self.receive(socket, generation)
                    case .waiting(let error), .failed(let error):
                        if check.snapshot().1 { self.fail("The TV identity changed or pairing was revoked. Explicitly forget and pair again.", retry: false) }
                        else { self.networkFailure(error, socket: socket) }
                    default: break
                    }
                }
            }
            monitorPath()
            socket.start(queue: queue)
            armDeadline(seconds: pairingChannel ? 30 : 10, reason: "TV service is unreachable or did not finish connecting. Power state is unknown.")
        } catch {
            let detail: String
            if case TVIdentityError.keychain(let status) = error {
                detail = "Keychain error \(status)."
            } else if let identityError = error as? TVIdentityError, identityError == .rePairRequired {
                detail = "Client identity is incomplete or inconsistent."
            } else { detail = "Client certificate could not be prepared." }
            fail("TV client credentials are unavailable. \(detail) Unlock the iPad and Retry; if needed, use Forget TV pairing and pair again.", retry: false)
        }
    }

    // Security invokes this on a background queue. Construct outside MainActor and
    // mark Sendable so Swift 6 cannot insert a main-executor assertion at callback entry.
    nonisolated private static func makePeerVerifier(pairingChannel: Bool, saved: TVSavedPairing?,
                                                    check: TVPeerCheck) -> sec_protocol_verify_t {
        { @Sendable _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = SecTrustGetCertificateAtIndex(reference, 0) else {
                check.record(nil, rejected: true); complete(false); return
            }
            let der = SecCertificateCopyData(certificate) as Data
            do {
                // Candidate acceptance is restricted to pairing; the PIN binds both keys.
                if !pairingChannel {
                    guard let saved else { throw TVIdentityError.rePairRequired }
                    try TVIdentityStore.verifyPeerCertificate(der, pairing: saved)
                }
                check.record(der, rejected: false); complete(true)
            } catch { check.record(nil, rejected: true); complete(false) }
        }
    }

    private func receive(_ socket: NWConnection, _ generation: UInt64) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { @Sendable [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.matches(socket, generation) else { return }
                if let data {
                    let frames = self.reader.feed(data)
                    if self.reader.failure != nil { self.fail("Malformed or oversized TV message.", retry: false); return }
                    for frame in frames {
                        guard self.matches(socket, generation) else { return }
                        if self.pairStep != nil { self.handlePair(frame) } else { self.handleRemote(frame) }
                    }
                }
                guard self.matches(socket, generation) else { return }
                if let error { self.networkFailure(error, socket: socket) }
                else if complete { self.fail("TV connection closed. Power state is unknown.", retry: true) }
                else { self.receive(socket, generation) }
            }
        }
    }

    private func handlePair(_ body: Data) {
        let encoding = TVEncoding(type: .hexadecimal, symbolLength: 6)
        switch (pairStep, TVWire.decodePolo(body)) {
        case (.request, .pairingRequestAck):
            pairStep = .options
            send(TVWire.encodedPolo(.options(inputEncodings: [encoding], outputEncodings: [], preferredRole: .input)))
        case (.options, .options(_, let outputs, _)):
            guard outputs.contains(encoding) else { fail("TV does not offer six-character hexadecimal pairing.", retry: false); return }
            pairStep = .configuration
            send(TVWire.encodedPolo(.configuration(encoding: encoding, clientRole: .input)))
        case (.configuration, .configurationAck):
            pairStep = .code; isAwaitingCode = true
            armDeadline(seconds: 120, reason: "Pairing code entry expired. Start pairing again.")
        case (.secret, .secretAck):
            guard let certificate = peer.snapshot().0 else { fail("Pairing has no verified peer identity.", retry: false); return }
            do {
                try TVIdentityStore.savePairing(host: host, certificateDER: certificate, label: deviceLabel)
                pairing = try TVIdentityStore.loadPairing(); isPaired = pairing != nil
                open(pairingChannel: false, reconnecting: false)
            } catch { fail("The TV confirmed pairing but its credentials could not be saved. Retry pairing.", retry: false) }
        default: fail("TV rejected pairing or sent an unexpected handshake. Start pairing again.", retry: false)
        }
    }

    private func handleRemote(_ body: Data) {
        guard TVProtobuf.decode(body) != nil else { fail("Malformed TV message.", retry: false); return }
        switch TVRemoteWire.decode(body) {
        case .configure(let features, let device):
            guard let response = session.noteRemoteConfigure(supported: features, deviceInfo: device) else {
                fail("TV does not support remote keys.", retry: false); return
            }
            configured = true; send(response)
        case .setActive:
            if let response = session.noteRemoteSetActive() { send(response) }
        case .pingRequest(let first, let second):
            if let response = session.notePingRequest(val1: first, val2: second) { send(response) }
        case .start(let started):
            guard configured else { fail("TV started without negotiating remote features.", retry: false); return }
            session.markConnected(); session.noteRemoteStart(started: started)
            deadline?.cancel(); deadline = nil; powerDeadline?.cancel(); powerDeadline = nil
            // Preserve the retry budget across short-lived connections; explicit retry or
            // a network/foreground return replenishes it, preventing an infinite loop.
            if let certificate = peer.snapshot().0 {
                do {
                    try TVIdentityStore.savePairing(host: host, certificateDER: certificate, label: deviceLabel)
                    pairing = try TVIdentityStore.loadPairing()
                } catch { lastError = "Connected, but the updated address could not be saved." }
            }
        case .imeKeyInject(let fields):
            let appInfo = TVProtobuf.nested(fields, 1)
            session.noteCurrentApp(appInfo.flatMap { TVProtobuf.string($0, 12) })
            noteField(fields)
        case .imeShowRequest(let fields): noteField(fields)
        case .imeBatchEdit(let ime, let field): session.noteIMEBatchEdit(imeCounter: ime, fieldCounter: field)
        case .remoteError: fail("TV Remote Service rejected a command. Retry or explicitly re-pair.", retry: false); return
        default: break // Unknown future messages are harmless; their bounded envelope was parsed.
        }
        publish()
    }

    private func noteField(_ fields: [TVWireField]) {
        if let field = TVProtobuf.nested(fields, 2) {
            let counter = Int32(truncatingIfNeeded: TVProtobuf.varint(field, 1) ?? 0)
            // No metadata => no text capability. Never infer a field from a batch alone.
            session.noteIMEField(counter: counter, active: true, supported: true)
        } else { session.markTextEntryUnsupported(reason: "TV has no supported active input field.") }
    }

    private func send(_ frame: TVOutgoingRemote) { send(TVRemoteWire.encoded(frame)) }
    private func send(_ data: Data) {
        guard active, let socket = connection else { return }
        let generation = sessionGeneration
        socket.send(content: data, completion: .contentProcessed { @Sendable [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self, self.matches(socket, generation) else { return }
                self.networkFailure(error, socket: socket)
            }
        })
    }
    private func matches(_ socket: NWConnection, _ generation: UInt64) -> Bool {
        active && connection === socket && sessionGeneration == generation
    }
    private func closeOldConnection() {
        deadline?.cancel(); deadline = nil; powerDeadline?.cancel(); powerDeadline = nil
        reconnect?.cancel(); reconnect = nil
        let releases = session.releaseAllHeldKeys().map(TVRemoteWire.encoded)
        let old = connection; connection = nil
        sessionGeneration &+= 1; reader.reset(); pairStep = nil; isAwaitingCode = false
        currentApp = nil; launchFeedback = nil
        if let old {
            old.stateUpdateHandler = nil
            if !releases.isEmpty {
                var data = Data(); releases.forEach { data.append($0) }
                old.send(content: data, completion: .contentProcessed { @Sendable _ in old.cancel() })
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { old.cancel() }
            } else { old.cancel() }
        }
    }
    private func publish() {
        state = session.connection; power = session.power; powerPending = session.pendingPower
        currentApp = session.currentApp
    }
    private func armDeadline(seconds: UInt64, reason: String) {
        deadline?.cancel(); let generation = sessionGeneration
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            guard let self, self.sessionGeneration == generation else { return }
            self.fail(reason, retry: self.pairStep == nil)
        }
    }
    private func networkFailure(_ error: NWError, socket: NWConnection) {
        if socket.currentPath?.unsatisfiedReason == .localNetworkDenied || error == .posix(.EPERM) || error == .posix(.EACCES) {
            closeOldConnection(); session.markLocalNetworkDenied(); publish()
            lastError = "Local network access denied. Enable it for BTRemote in iPad Settings, then Retry."
        } else if case .tls = error {
            fail("TLS authentication failed. Check the TV and explicitly re-pair if its credentials changed.", retry: false)
        } else { fail("TV service is unreachable. Check its address, Wi-Fi and network standby; power state is unknown.", retry: true) }
    }
    private func fail(_ reason: String, retry: Bool) {
        closeOldConnection(); session.markUnavailable(reason); lastError = reason; publish()
        guard retry, active, requested, pairing != nil, retries < 3 else { return }
        let delay = UInt64(1 << retries); retries += 1
        let generation = sessionGeneration
        reconnect = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self, self.active, self.requested, self.sessionGeneration == generation else { return }
            self.open(pairingChannel: false, reconnecting: true)
        }
    }
    private func monitorPath() {
        guard pathMonitor == nil else { return }
        lastPathAvailable = false
        pathObserved = false
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.pathMonitor === monitor, self.active else { return }
                self.pathObserved = true
                let returned = available && !self.lastPathAvailable
                self.lastPathAvailable = available
                if returned, self.connection == nil, self.requested, self.pairing != nil {
                    self.retries = 0; self.open(pairingChannel: false, reconnecting: true)
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Executes the production NWPathMonitor callback on its real background queue.
    /// No connection, key creation, pairing, or local-network request is performed.
    static func runNoNetworkCallbackCheck() async -> Bool {
        let probe = TVRemoteClient()
        probe.monitorPath()
        defer { probe.disconnect() }
        for _ in 0..<100 {
            if probe.pathObserved { return true }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
        return false
    }

    #if os(macOS)
    /// CI-only loopback TLS fixture invokes the SAME Security callback as Pair.
    /// No TV credentials/pins are created or saved; traffic stays on 127.0.0.1.
    static func runLoopbackTLSCallbackCheck(port: UInt16) async -> (candidate: Bool, pinned: Bool, mismatch: Bool) {
        func probe(pairingChannel: Bool, saved: TVSavedPairing?) async -> (Data?, Bool) {
            let check = TVPeerCheck()
            let tls = NWProtocolTLS.Options()
            let callbackQueue = DispatchQueue(label: "BTRemote.TV.callback-test")
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions,
                makePeerVerifier(pairingChannel: pairingChannel, saved: saved, check: check), callbackQueue)
            let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            defer { socket.cancel() }
            socket.start(queue: callbackQueue)
            for _ in 0..<100 {
                let outcome = check.snapshot()
                if outcome.0 != nil || outcome.1 { return outcome }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return (nil, false) }
            }
            return (nil, false)
        }
        let candidate = await probe(pairingChannel: true, saved: nil)
        guard let der = candidate.0, !candidate.1 else { return (false, false, false) }
        let saved = TVSavedPairing(host: "127.0.0.1", label: "CI fixture", serverCertificateSHA256: Data(SHA256.hash(data: der)))
        let pinned = await probe(pairingChannel: false, saved: saved)
        var changed = saved; changed.serverCertificateSHA256 = Data(repeating: 0, count: 32)
        let mismatch = await probe(pairingChannel: false, saved: changed)
        return (true, pinned.0 == der && !pinned.1, mismatch.0 == nil && mismatch.1)
    }
    #endif
    static func privateAddress(_ address: String) -> Bool {
        guard !address.isEmpty, address == address.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if let ipv4 = IPv4Address(address) {
            let bytes = Array(ipv4.rawValue)
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
        }
        if let ipv6 = IPv6Address(address) {
            let bytes = Array(ipv6.rawValue)
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return false
    }
}
