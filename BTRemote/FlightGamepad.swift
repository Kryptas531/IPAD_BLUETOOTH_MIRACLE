import Foundation

/// Navigation disarms FLIGHT until an explicit action, independent of persisted mode.
struct GameNavigationPolicy {
    private(set) var flightNeedsRearm = false
    mutating func present() { flightNeedsRearm = true }
    mutating func explicitlyRearm() { flightNeedsRearm = false }
    func permitsAutomaticStart(_ mode: GameInputMode, presenting: Bool) -> Bool {
        !presenting && (mode != .flight || !flightNeedsRearm)
    }
}

/// Explicit gameplay budget: native views cannot enlarge the parent beyond this frame.
struct FlightDeckLayout {
    let bodyHeight: Double
    init(width: Double, height: Double) {
        bodyHeight = max(height, width > height ? 360 : 580)
    }
}

/// A delayed callback cannot replay old deflected state. No queued sample storage.
struct FlightCadence {
    private var lastTick: TimeInterval?
    private(set) var inFlightSince: TimeInterval?
    mutating func tick(now: TimeInterval) -> Bool {
        defer { lastTick = now }
        if let lastTick, now - lastTick >= 0.100 { return false }
        if let inFlightSince, now - inFlightSince >= 0.100 { return false }
        return true
    }
    mutating func beganSend(now: TimeInterval) { inFlightSince = now }
    mutating func completedSend(now: TimeInterval) -> Bool {
        defer { inFlightSince = nil }
        guard let inFlightSince else { return false }
        return now - inFlightSince < 0.100
    }
}

/// Pure FLIGHT arithmetic and wire format (SPEC §13); no BLE descriptor changes.
enum FlightMapper {
    static func axes(from baseline: RacingQuaternion, to current: RacingQuaternion,
                     landscapeRight: Bool) -> (lx: Int8, ly: Int8) {
        let values = [baseline.w, baseline.x, baseline.y, baseline.z,
                      current.w, current.x, current.y, current.z]
        guard values.allSatisfy({ $0.isFinite }) else { return (0, 0) }
        let dot = baseline.w * current.w + baseline.x * current.x
            + baseline.y * current.y + baseline.z * current.z
        let sign = dot < 0 ? -1.0 : 1.0
        let w = dot * sign
        let x = (baseline.w * current.x - baseline.x * current.w
            - baseline.y * current.z + baseline.z * current.y) * sign
        let y = (baseline.w * current.y - baseline.y * current.w
            + baseline.x * current.z - baseline.z * current.x) * sign
        let z = (baseline.w * current.z - baseline.z * current.w
            - baseline.x * current.y + baseline.y * current.x) * sign
        let norm = sqrt(x * x + y * y + z * z)
        guard norm.isFinite, norm > 1e-9 else { return (0, 0) }
        let scale = 2 * atan2(norm, w) / norm * 180 / Double.pi
        // Landscape's horizontal physical axis is device Y, reversed between orientations.
        return (RacingMapper.axis(fromAngle: -z * scale),
                RacingMapper.axis(fromAngle: y * scale * (landscapeRight ? -1 : 1),
                                  fullLock: 25))
    }
}

enum FlightConfiguration {
    static func privateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let nums = parts.compactMap { UInt8($0) }
        guard nums.count == 4, parts.map(String.init) == nums.map({ String($0) }) else { return false }
        return nums[0] == 10 || (nums[0] == 172 && (16...31).contains(nums[1]))
            || (nums[0] == 192 && nums[1] == 168)
    }
    static func keyData(_ hex: String) -> Data? {
        guard hex.count == 64, hex.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        var data = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            data.append(byte)
            cursor = next
        }
        return data
    }
}

struct FlightState: Equatable, Sendable {
    var buttons: UInt16 = 0
    var lx: Int8 = 0
    var ly: Int8 = 0
    var rx: Int8 = 0
    var ry: Int8 = 0
    var lt: UInt8 = 0
    var rt: UInt8 = 0
    static let zero = FlightState()

    mutating func recenter() { lx = 0; ly = 0 }
    mutating func setButton(_ bit: UInt16, pressed: Bool) {
        if pressed { buttons |= bit & 0x3ff } else { buttons &= ~bit }
    }

    func payload(session: UUID, sequence: UInt64) -> Data {
        var uuid = session.uuid
        var bytes = Data("IGP1".utf8)
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: sequence >> shift))
        }
        bytes.append(UInt8(truncatingIfNeeded: buttons >> 8))
        bytes.append(UInt8(truncatingIfNeeded: buttons & 0xff))
        bytes.append(contentsOf: [UInt8(bitPattern: GamepadReport.clampSigned(lx)),
                                 UInt8(bitPattern: GamepadReport.clampSigned(ly)),
                                 UInt8(bitPattern: GamepadReport.clampSigned(rx)),
                                 UInt8(bitPattern: GamepadReport.clampSigned(ry)), lt, rt])
        return bytes
    }
}

/// Retain brief edges across the 20 ms heartbeat and at least several game polls.
/// Deadlines begin at first transmission, not at touch-down while a send is busy.
struct FlightButtonLatch {
    private var held: UInt16 = 0
    private var pending: UInt16 = 0
    private var deadlines: [Int: TimeInterval] = [:]

    mutating func update(_ buttons: UInt16) {
        pending |= buttons & ~held & 0x3ff
        held = buttons & 0x3ff
    }

    mutating func sample(now: TimeInterval) -> UInt16 {
        for bit in 0..<10 where pending & (1 << bit) != 0 {
            deadlines[bit] = now + 0.080
        }
        pending = 0
        var result = held
        for (bit, deadline) in deadlines {
            if now < deadline { result |= 1 << bit }
        }
        deadlines = deadlines.filter { now < $0.value }
        return result
    }
}

/// Fresh-session recovery: 30 neutral frames at 50 Hz span the old owner's watchdog.
struct FlightStream {
    private(set) var session = UUID()
    private(set) var sequence: UInt64 = 0
    private var neutralRemaining = 30

    var isArmed: Bool { neutralRemaining == 0 }

    mutating func next(_ latest: FlightState) -> Data {
        sequence += 1
        let state = neutralRemaining > 0 ? FlightState.zero : latest
        neutralRemaining = max(0, neutralRemaining - 1)
        return state.payload(session: session, sequence: sequence)
    }
}

/// A re-arm discards held input until its corresponding release/new gesture.
struct FlightReleaseGate {
    private var buttons: UInt16 = 0
    private var lt = false
    private var rt = false
    private(set) var camera = false

    mutating func rearm(held: FlightState, dragging: Bool) {
        buttons |= held.buttons
        lt = lt || held.lt != 0
        rt = rt || held.rt != 0
        camera = camera || dragging
    }
    mutating func button(_ bit: UInt16, pressed: Bool) -> Bool {
        if !pressed { buttons &= ~bit }
        return buttons & bit == 0
    }
    mutating func trigger(right: Bool, pressed: Bool) -> Bool {
        if right {
            if !pressed { rt = false }
            return !rt
        }
        if !pressed { lt = false }
        return !lt
    }
    mutating func endCamera() { camera = false }
}

#if os(iOS)
import CryptoKit
import Network
import SwiftUI
import Security

private enum FlightKeyStore {
    private static let service = "io.github.jqssun.btremote.flight"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "pairing-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String) -> Bool {
        guard FlightConfiguration.keyData(value) != nil,
              let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "pairing-key"]
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class FlightSender: ObservableObject {
    @Published private(set) var status = "Not configured"
    private var connection: NWConnection?
    private var heartbeat: Task<Void, Never>?
    private var stream = FlightStream()
    private var key: SymmetricKey?
    private var sending = false
    private var cadence = FlightCadence()
    private let networkQueue = DispatchQueue(label: "BTRemote.flight.network", qos: .userInteractive)
    var beforeTick: (() -> Void)?
    @Published private(set) var diagnostics = "No sends yet"
    private var sentCount = 0
    private var statsStarted: TimeInterval = 0
    var motionAge: TimeInterval?
    private var latest = FlightState.zero
    private var buttonLatch = FlightButtonLatch()

    func start() {
        stop()
        let host = UserDefaults.standard.string(forKey: "BTRemote.flightHost") ?? ""
        let hex = FlightKeyStore.read() ?? ""
        guard FlightConfiguration.privateIPv4(host),
              let bytes = FlightConfiguration.keyData(hex) else {
            status = "Enter Windows LAN IPv4 and 64-digit key in Settings"
            return
        }
        key = SymmetricKey(data: bytes)
        stream = FlightStream()
        let generation = stream.session
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 26761, using: .udp)
        connection = conn
        status = "Connecting UDP…"
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.stream.session == generation else { return }
                switch state {
                case .ready: self.status = "UDP sending · Wi-Fi"
                case .failed: self.stop(); self.status = "UDP failed — check Settings/network"
                case .waiting: self.status = "UDP waiting — check network"
                default: break
                }
            }
        }
        cadence = FlightCadence()
        sentCount = 0
        statsStarted = ProcessInfo.processInfo.systemUptime
        diagnostics = "Starting · no receiver ACK"
        conn.start(queue: networkQueue)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard self.cadence.tick(now: now) else {
                    let age = self.cadence.inFlightSince.map { Int(max(0, now - $0) * 1000) } ?? 0
                    self.stop()
                    self.status = "Sender stalled — RE-ARM"
                    self.diagnostics = "Tick/send exceeded 100 ms · pending \(age) ms"
                    return
                }
                self.beforeTick?()
                self.flush()
                if now - self.statsStarted >= 1 {
                    let hz = Double(self.sentCount) / (now - self.statsStarted)
                    let age = self.cadence.inFlightSince.map { Int(max(0, now - $0) * 1000) } ?? 0
                    let motion = self.motionAge.map { String(Int($0 * 1000)) } ?? "—"
                    self.diagnostics = String(format: "v%@ (%@) · %.0f sends/s · pending %d ms · motion %@ ms",
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", hz, age, motion)
                    self.sentCount = 0; self.statsStarted = now
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    func update(_ state: FlightState) {
        latest = state
        buttonLatch.update(state.buttons)
    }

    private func flush() {
        guard !sending, let connection, let key, connection.state == .ready else { return }
        // Neutral takeover spans the previous owner watchdog, including explicit re-arm.
        var sampled = latest
        if stream.isArmed {
            sampled.buttons = buttonLatch.sample(now: ProcessInfo.processInfo.systemUptime)
        }
        var packet = stream.next(sampled)
        packet.append(contentsOf: HMAC<SHA256>.authenticationCode(for: packet, using: key))
        sending = true
        cadence.beganSend(now: ProcessInfo.processInfo.systemUptime)
        let generation = stream.session
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.stream.session == generation else { return }
                self.sending = false
                guard self.cadence.completedSend(now: ProcessInfo.processInfo.systemUptime) else {
                    self.stop(); self.status = "Slow UDP completion — RE-ARM"
                    return
                }
                if error == nil { self.sentCount += 1 }
                if error != nil { self.stop(); self.status = "UDP send failed" }
            }
        })
    }

    func stop() {
        // Best-effort release; receiver's independent 300 ms watchdog is authoritative.
        beforeTick = nil
        motionAge = nil
        latest = .zero
        buttonLatch = FlightButtonLatch()
        flush()
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        connection = nil
        stream = FlightStream() // invalidate late callbacks from the old connection
        sending = false
        key = nil
        latest = .zero
        status = "Stopped"
    }
}

struct FlightStatusView: View {
    @ObservedObject var sender: FlightSender
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sender.status)
            Text(sender.diagnostics)
        }.font(.caption2)
    }
}

struct FlightSettingsView: View {
    @AppStorage("BTRemote.flightHost") private var host = ""
    @State private var key = ""
    @State private var keyStatus = ""
    var body: some View {
        Section(header: Text("Ace Combat / FLIGHT (Wi-Fi)"),
                footer: Text("Run the Windows FlightReceiver on your LAN. Enter its private IPv4 and pairing key. FLIGHT creates XInput through the receiver, not Bluetooth. Tap RECONNECT / RE-ARM in FLIGHT after changing settings.")) {
            TextField("Windows LAN IPv4", text: $host)
                .keyboardType(.decimalPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("64-digit pairing key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save pairing key") {
                keyStatus = FlightKeyStore.write(key) ? "Key saved in Keychain" : "Enter 64 hex digits; key was not saved"
            }
            if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
        }
        .onAppear { key = FlightKeyStore.read() ?? "" }
        // Key remains in Keychain, never in UserDefaults.
        .onDisappear { key = "" }
    }
}
#endif
