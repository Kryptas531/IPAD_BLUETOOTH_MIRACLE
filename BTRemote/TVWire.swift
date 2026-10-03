//
//  TVWire.swift
//  BTRemote
//
//  Foundation-only wire layer for the direct Wi-Fi TV target described in SPEC §7.3
//  ("Android TV Remote" v2 transport). It contains the protobuf field codec, the bounded
//  varint-length frame reader/writer, the Polo pairing message set, the Remote v2 message
//  set, the RSA/SHA-256 pairing-hash construction and a small pure session state model.
//
//  Pinned protocol references read for this implementation (local copies in
//  `.qwen/tmp/tv-784bad0/`; upstream `tronikos/androidtvremote2` inspected at commit
//  b09f21432ba33e42536215a8f41641d801cf6a2c):
//
//    polo.proto          https://android.googlesource.com/platform/external/google-tv-pairing-protocol/+/refs/heads/master/proto/polo.proto
//    remotemessage.proto https://github.com/louis49/androidtv-remote/blob/main/src/remote/remotemessage.proto
//    pairing.py          https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/pairing.py
//    remote.py           https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/remote.py
//    androidtv_remote.py https://github.com/tronikos/androidtvremote2/blob/b09f21432ba33e42536215a8f41641d801cf6a2c/src/androidtvremote2/androidtv_remote.py
//
//  No upstream source code is vendored and no license/dependency is introduced: field
//  numbers, enum values, the varint framing and the pairing hash construction below were
//  transcribed from the pinned definitions listed above. Do not "fix" a field number, a
//  feature bit or the hash byte order without re-reading those sources: the TV checks them.
//
//  Dependencies: Apple platform frameworks only (Foundation + CryptoKit). CryptoKit supplies
//  SHA-256 because the TV verifies the pairing hash byte-for-byte and a hand-rolled digest
//  could not be validated on this Windows machine (no Swift, no Node). No third-party package
//  is introduced, so the dependency-free `swiftc` test build used by CI still compiles this
//  file. Nothing in this file opens a socket, reads a keychain item or contacts a host.
//

import Foundation
import CryptoKit

// MARK: - Wire constants (pinned: androidtv_remote.py, polo.proto, remote.py)

/// TCP ports used by the TV's Android TV Remote Service.
public enum TVPort {
    /// Pairing endpoint — TLS, client certificate presented, code verified here only.
    public static let pairing: UInt16 = 6467
    /// Remote command endpoint — TLS, same client certificate, keys/IME/power after pairing.
    public static let remote: UInt16 = 6466
}

/// Fixed protocol strings and the outer protocol version actually transmitted.
///
/// `polo.proto` declares `protocol_version` with `[default = 1]`, but the pinned reference
/// client builds every outgoing `OuterMessage` with `protocol_version = 2` (`pairing.py`,
/// `_create_message`). The TV is the party that reads this field, so the reference value is
/// preserved verbatim — do not change it to the proto default.
public enum TVProtocol {
    public static let serviceName = "atvremote"
    public static let clientName = "BTRemote"
    public static let protocolVersion: UInt64 = 2
}

/// Bounded sizes. A malformed or hostile peer must never make the app allocate or wait
/// without limit, and a truncated frame must never be decoded as a complete one.
public enum TVLimits {
    /// Longest varint we accept (10 bytes covers a full unsigned 64-bit varint).
    public static let maxVarintBytes = 10
    /// Largest single framed protobuf message we accept.
    public static let maxMessageBytes = 1 << 20
    /// Largest field payload inside one message (same bound as a whole message).
    public static let maxFieldBytes = 1 << 20
}

// MARK: - Failures

public enum TVWireFailure: Error, Equatable, CustomStringConvertible {
    case truncatedVarint
    case varintOverflow
    case truncatedField(number: Int32)
    case fieldTooLarge(number: Int32, length: UInt64)
    case invalidFieldNumber(UInt64)
    case unsupportedWireType(UInt8)
    case messageTooLarge(length: UInt64)
    case invalidPairingCode(String)
    case pairingHashMismatch(String)
    case invalidKeyMaterial(String)
    case unexpectedMessage(String)

    public var description: String {
        switch self {
        case .truncatedVarint: return "A length varint was cut off by the end of the buffer."
        case .varintOverflow: return "A varint was longer than \(TVLimits.maxVarintBytes) bytes."
        case .truncatedField(let number): return "Field \(number) is shorter than its declared length."
        case .fieldTooLarge(let number, let length): return "Field \(number) declared \(length) bytes, over the bounded limit."
        case .invalidFieldNumber(let number): return "Field number \(number) is not a valid protobuf field number."
        case .unsupportedWireType(let wire): return "Protobuf wire type \(wire) is not supported."
        case .messageTooLarge(let length): return "Framed message of \(length) bytes exceeds the bounded limit."
        case .invalidPairingCode(let detail): return "Pairing code was not accepted: \(detail)"
        case .pairingHashMismatch: return "The pairing code did not match the peer's key material."
        case .invalidKeyMaterial(let detail): return "Could not read RSA key material: \(detail)"
        case .unexpectedMessage(let detail): return "Unexpected message from the TV: \(detail)"
        }
    }
}

// MARK: - Protobuf primitives (Foundation only, no generated code, no dependencies)

/// Wire types needed by the two `.proto` definitions above. `group` (3/4) is intentionally
/// absent: neither pinned definition uses it, so a peer sending one is a protocol error.
public enum TVWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

/// One decoded/encodable field value. `bytes` also carries `string` and nested `message`
/// payloads (both are length-delimited on the wire), so encoding and decoding are symmetric.
public enum TVFieldValue: Equatable, Sendable {
    case varint(UInt64)
    case bytes(Data)
    case fixed32(Data)
    case fixed64(Data)
}

public struct TVWireField: Equatable, Sendable {
    public var number: Int32
    public var value: TVFieldValue

    public init(number: Int32, value: TVFieldValue) {
        self.number = number
        self.value = value
    }
}

public enum TVProtobuf {
    /// Tags themselves are varints, including fields 20, 40 and 50.
    static func tag(_ number: Int32, _ wire: TVWireType) -> Data {
        precondition(number > 0 && number < (1 << 29))
        return encodeVarint((UInt64(number) << 3) | UInt64(wire.rawValue))
    }

    public static func varintField(_ number: Int32, _ value: UInt64) -> TVWireField {
        TVWireField(number: number, value: .varint(value))
    }

    public static func stringField(_ number: Int32, _ value: String) -> TVWireField {
        TVWireField(number: number, value: .bytes(Data(value.utf8)))
    }

    public static func dataField(_ number: Int32, _ value: Data) -> TVWireField {
        TVWireField(number: number, value: .bytes(value))
    }

    public static func messageField(_ number: Int32, _ fields: [TVWireField]) -> TVWireField {
        TVWireField(number: number, value: .bytes(encode(fields)))
    }

    public static func encodeVarint(_ value: UInt64) -> Data {
        var out = Data()
        var remaining = value
        while remaining > 0x7F {
            out.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining))
        return out
    }

    /// Decode a varint starting at `offset`. Returns `.truncated` when more bytes are needed
    /// (the peer has not sent a whole varint yet) and `.overflow` when the varint runs past
    /// the bounded byte count, which is a protocol error rather than a fragment.
    public static func decodeVarint(_ bytes: [UInt8], offset: Int) -> (value: UInt64, next: Int)? {
        guard offset >= 0, offset <= bytes.count else { return nil }
        var result: UInt64 = 0
        for position in 0..<10 {
            guard offset + position < bytes.count else { return nil }
            let byte = bytes[offset + position]
            if position == 9 && byte > 1 { return nil }
            result |= UInt64(byte & 0x7F) << UInt64(position * 7)
            if byte & 0x80 == 0 { return (result, offset + position + 1) }
        }
        return nil
    }

    /// Encode a message as an ordered field list. Field order on the wire follows the order
    /// of `fields`, so tests can assert exact bytes.
    public static func encode(_ fields: [TVWireField]) -> Data {
        var out = Data()
        for field in fields {
            switch field.value {
            case .varint(let value):
                out.append(tag(field.number, .varint))
                out.append(encodeVarint(value))
            case .bytes(let payload):
                out.append(tag(field.number, .lengthDelimited))
                out.append(encodeVarint(UInt64(payload.count)))
                out.append(payload)
            case .fixed32(let payload):
                out.append(tag(field.number, .fixed32))
                out.append(payload)
            case .fixed64(let payload):
                out.append(tag(field.number, .fixed64))
                out.append(payload)
            }
        }
        return out
    }

    /// Decode into a field list. `nil` means the data is not a valid message: truncated
    /// varints/fields, an over-long varint, an oversized length or an unsupported wire type.
    /// Unknown fields are preserved rather than dropped, so a fixture can assert on them.
    public static func decode(_ data: Data) -> [TVWireField]? {
        var fields: [TVWireField] = []
        var bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard let decodedTag = decodeVarint(bytes, offset: offset) else { return nil }
            offset = decodedTag.next
            let fieldNumber = decodedTag.value >> 3
            let wireType = UInt8(decodedTag.value & 0x7)
            guard fieldNumber > 0, fieldNumber < (1 << 29) else {
                return nil
            }
            switch wireType {
            case TVWireType.varint.rawValue:
                guard let decodedValue = decodeVarint(bytes, offset: offset) else { return nil }
                fields.append(TVWireField(number: Int32(truncatingIfNeeded: fieldNumber), value: .varint(decodedValue.value)))
                offset = decodedValue.next
            case TVWireType.lengthDelimited.rawValue:
                guard let decodedLength = decodeVarint(bytes, offset: offset) else { return nil }
                offset = decodedLength.next
                guard let length = Int(exactly: decodedLength.value), length <= TVLimits.maxFieldBytes else {
                    return nil
                }
                guard offset + length <= bytes.count else { return nil }
                let payload = Data(bytes[offset..<(offset + length)])
                offset += length
                fields.append(TVWireField(number: Int32(truncatingIfNeeded: fieldNumber), value: .bytes(payload)))
            case TVWireType.fixed32.rawValue:
                guard offset + 4 <= bytes.count else { return nil }
                let payload = Data(bytes[offset..<(offset + 4)])
                offset += 4
                fields.append(TVWireField(number: Int32(truncatingIfNeeded: fieldNumber), value: .fixed32(payload)))
            case TVWireType.fixed64.rawValue:
                guard offset + 8 <= bytes.count else { return nil }
                let payload = Data(bytes[offset..<(offset + 8)])
                offset += 8
                fields.append(TVWireField(number: Int32(truncatingIfNeeded: fieldNumber), value: .fixed64(payload)))
            default:
                return nil
            }
        }
        return fields
    }

    // Convenience accessors used by the client and by fixture tests.

    public static func varint(_ fields: [TVWireField], _ number: Int32) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    public static func data(_ fields: [TVWireField], _ number: Int32) -> Data? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    public static func string(_ fields: [TVWireField], _ number: Int32) -> String? {
        guard let payload = data(fields, number) else { return nil }
        return String(data: payload, encoding: .utf8)
    }

    public static func nested(_ fields: [TVWireField], _ number: Int32) -> [TVWireField]? {
        guard let payload = data(fields, number) else { return nil }
        return decode(payload)
    }
}

// MARK: - Framing (varint length + payload)

public enum TVFrame {
    /// One framed protobuf message: varint byte count followed by that many bytes.
    public static func encoded(_ message: Data) -> Data {
        var out = TVProtobuf.encodeVarint(UInt64(message.count))
        out.append(message)
        return out
    }

    /// Encode a field-list message and frame it, for tests and for the client.
    public static func encoded(_ fields: [TVWireField]) -> Data {
        encoded(TVProtobuf.encode(fields))
    }
}

/// Incremental, bounded frame reader for a byte stream. Feed arbitrary TCP chunks; complete
/// messages come back in order. A malformed stream latches `failure` and stops yielding
/// messages — it is never silently repaired. `reset()` starts a new session (reconnect),
/// which discards any partial frame and any latched failure from the old one.
public struct TVFrameReader: Sendable {
    public let maxMessageBytes: Int
    public private(set) var failure: TVWireFailure?
    private var buffer: [UInt8] = []

    public init(maxMessageBytes: Int = TVLimits.maxMessageBytes) {
        self.maxMessageBytes = maxMessageBytes
    }

    public mutating func feed(_ chunk: Data) -> [Data] {
        guard failure == nil else { return [] }
        buffer.append(contentsOf: chunk)
        var messages: [Data] = []
        while !buffer.isEmpty {
            guard let header = TVProtobuf.decodeVarint(buffer, offset: 0) else {
                if buffer.count >= TVLimits.maxVarintBytes {
                    failure = .varintOverflow
                }
                return messages
            }
            guard let length = Int(exactly: header.value), length <= maxMessageBytes else {
                failure = .messageTooLarge(length: header.value)
                return messages
            }
            guard buffer.count - header.next >= length else {
                return messages
            }
            messages.append(Data(buffer[header.next..<(header.next + length)]))
            buffer = Array(buffer[(header.next + length)...])
        }
        return messages
    }

    /// Bytes not yet forming a complete frame (diagnostics/tests only).
    public var pendingByteCount: Int { buffer.count }

    public mutating func reset() {
        buffer = []
        failure = nil
    }
}

// MARK: - Polo pairing messages (pinned: polo.proto field numbers, pairing.py behavior)

public enum TVPoloStatus: UInt64, Sendable {
    case ok = 200
    case error = 400
    case badConfiguration = 401
    case badSecret = 402
}

public enum TVEncodingType: UInt64, Sendable {
    case unknown = 0
    case alphanumeric = 1
    case numeric = 2
    case hexadecimal = 3
    case qrCode = 4
}

public enum TVRoleType: UInt64, Sendable {
    case unknown = 0
    case input = 1
    case output = 2
}

public struct TVEncoding: Equatable, Sendable {
    public var type: TVEncodingType
    public var symbolLength: UInt64

    public init(type: TVEncodingType, symbolLength: UInt64) {
        self.type = type
        self.symbolLength = symbolLength
    }
}

/// Messages the iPad sends on the pairing channel (field 10/20/30/40 of `OuterMessage`).
public enum TVOutgoingPolo: Equatable, Sendable {
    case pairingRequest(serviceName: String, clientName: String)
    case options(inputEncodings: [TVEncoding], outputEncodings: [TVEncoding], preferredRole: TVRoleType)
    case configuration(encoding: TVEncoding, clientRole: TVRoleType)
    case secret(Data)
}

/// Messages received on the pairing channel.
public enum TVIncomingPolo: Equatable, Sendable {
    case pairingRequestAck(serverName: String?)
    case options(inputEncodings: [TVEncoding], outputEncodings: [TVEncoding], preferredRole: TVRoleType?)
    case configuration(encoding: TVEncoding?, clientRole: TVRoleType?)
    case configurationAck
    case secretAck(Data)
    case rejected(status: TVPoloStatus?, fields: [TVWireField])
    case undecodable(fields: [TVWireField])
}

public enum TVWire {
    /// Build one outgoing Polo `OuterMessage` (protocol_version=2, status=200, one payload).
    public static func encodedPolo(_ outgoing: TVOutgoingPolo) -> Data {
        var fields: [TVWireField] = [
            TVProtobuf.varintField(1, TVProtocol.protocolVersion),
            TVProtobuf.varintField(2, TVPoloStatus.ok.rawValue),
        ]
        switch outgoing {
        case .pairingRequest(let service, let client):
            fields.append(TVProtobuf.messageField(10, [
                TVProtobuf.stringField(1, service),
                TVProtobuf.stringField(2, client),
            ]))
        case .options(let inputEncodings, let outputEncodings, let preferredRole):
            var optionFields: [TVWireField] = []
            for encoding in inputEncodings {
                optionFields.append(TVProtobuf.messageField(1, encodeEncoding(encoding)))
            }
            for encoding in outputEncodings {
                optionFields.append(TVProtobuf.messageField(2, encodeEncoding(encoding)))
            }
            optionFields.append(TVProtobuf.varintField(3, preferredRole.rawValue))
            fields.append(TVProtobuf.messageField(20, optionFields))
        case .configuration(let encoding, let clientRole):
            fields.append(TVProtobuf.messageField(30, [
                TVProtobuf.messageField(1, encodeEncoding(encoding)),
                TVProtobuf.varintField(2, clientRole.rawValue),
            ]))
        case .secret(let digest):
            fields.append(TVProtobuf.messageField(40, [TVProtobuf.dataField(1, digest)]))
        }
        return TVFrame.encoded(fields)
    }

    private static func encodeEncoding(_ encoding: TVEncoding) -> [TVWireField] {
        [
            TVProtobuf.varintField(1, encoding.type.rawValue),
            TVProtobuf.varintField(2, encoding.symbolLength),
        ]
    }

    /// Parse one framed Polo message received from the TV.
    public static func decodePolo(_ message: Data) -> TVIncomingPolo {
        guard let fields = TVProtobuf.decode(message) else {
            return .undecodable(fields: [])
        }
        let statusRaw = TVProtobuf.varint(fields, 2)
        let status = statusRaw.flatMap(TVPoloStatus.init(rawValue:))
        guard status == .ok else { return .rejected(status: status, fields: fields) }
        if let ack = TVProtobuf.nested(fields, 11) {
            return .pairingRequestAck(serverName: TVProtobuf.string(ack, 1))
        }
        if let options = TVProtobuf.nested(fields, 20) {
            var inputEncodings: [TVEncoding] = []
            var outputEncodings: [TVEncoding] = []
            for field in options {
                guard case .bytes(let payload) = field.value,
                      let encodingFields = TVProtobuf.decode(payload),
                      let type = TVProtobuf.varint(encodingFields, 1).flatMap(TVEncodingType.init(rawValue:)),
                      let symbolLength = TVProtobuf.varint(encodingFields, 2)
                else { continue }
                let encoding = TVEncoding(type: type, symbolLength: symbolLength)
                if field.number == 1 { inputEncodings.append(encoding) }
                if field.number == 2 { outputEncodings.append(encoding) }
            }
            return .options(
                inputEncodings: inputEncodings,
                outputEncodings: outputEncodings,
                preferredRole: TVProtobuf.varint(options, 3).flatMap(TVRoleType.init(rawValue:))
            )
        }
        if let configuration = TVProtobuf.nested(fields, 30) {
            var encoding: TVEncoding?
            if let encodingFields = TVProtobuf.nested(configuration, 1),
               let type = TVProtobuf.varint(encodingFields, 1).flatMap(TVEncodingType.init(rawValue:)),
               let symbolLength = TVProtobuf.varint(encodingFields, 2) {
                encoding = TVEncoding(type: type, symbolLength: symbolLength)
            }
            return .configuration(
                encoding: encoding,
                clientRole: TVProtobuf.varint(configuration, 2).flatMap(TVRoleType.init(rawValue:))
            )
        }
        if TVProtobuf.nested(fields, 31) != nil {
            return .configurationAck
        }
        if let ack = TVProtobuf.nested(fields, 41) {
            return .secretAck(TVProtobuf.data(ack, 1) ?? Data())
        }
        return .undecodable(fields: fields)
    }

    public struct TVRSAKeyMaterial: Equatable, Sendable {
        public var modulus: Data
        public var exponent: Data
        public init(modulus: Data, exponent: Data) {
            self.modulus = modulus
            self.exponent = exponent
        }
    }

    /// pairing.py: unsigned big-endian RSA integers, then the PIN's final two bytes.
    public static func pairingSecret(clientKey: TVRSAKeyMaterial,
                                     serverKey: TVRSAKeyMaterial, code: String) -> Data? {
        let chars = Array(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard chars.count == 6, !clientKey.modulus.isEmpty, !clientKey.exponent.isEmpty,
              !serverKey.modulus.isEmpty, !serverKey.exponent.isEmpty else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var pin = [UInt8]()
        for i in stride(from: 0, to: 6, by: 2) {
            guard let a = nibble(chars[i]), let b = nibble(chars[i + 1]) else { return nil }
            pin.append(a * 16 + b)
        }
        let bytes = clientKey.modulus + clientKey.exponent + serverKey.modulus
            + serverKey.exponent + Data(pin.suffix(2))
        let digest = Data(SHA256.hash(data: bytes))
        return digest.first == pin[0] ? digest : nil
    }
}

// MARK: - Remote v2 messages (pinned: remotemessage.proto field numbers, remote.py behavior)

/// Only the key codes this product's TV surface needs, with the exact `RemoteKeyCode` values
/// from `remotemessage.proto`. Anything else the TV might accept is deliberately absent —
/// sending an unlisted code would be inventing protocol.
public enum TVKeycode: Int32, Sendable, CaseIterable {
    case home = 3
    case back = 4
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
    case ok = 23
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case mediaPlayPause = 85
    case volumeMute = 164
}

/// `RemoteDirection`: a click is `short`; a press and its release are `startLong`/`endLong`.
public enum TVKeyDirection: Int32, Sendable {
    case unknown = 0
    case startLong = 1
    case endLong = 2
    case short = 3
}

/// Feature bits from `remote.py` `class Feature(IntFlag)`. `appLink` is listed for
/// completeness; the TV target does not launch apps, so it is not requested.
public struct TVFeature: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let ping = TVFeature(rawValue: 1 << 0)
    public static let key = TVFeature(rawValue: 1 << 1)
    public static let ime = TVFeature(rawValue: 1 << 2)
    public static let voice = TVFeature(rawValue: 1 << 3)
    public static let unknown1 = TVFeature(rawValue: 1 << 4)
    public static let power = TVFeature(rawValue: 1 << 5)
    public static let volume = TVFeature(rawValue: 1 << 6)
    public static let appLink = TVFeature(rawValue: 1 << 9)

    /// What the iPad asks the TV for. Text is only possible with a negotiated IME.
    public static let requested: TVFeature = [.ping, .key, .ime, .power, .volume]
}

public struct TVDeviceInfo: Equatable, Sendable {
    public var model: String?
    public var vendor: String?
    public var unknown1: UInt64
    public var unknown2: String
    public var packageName: String
    public var appVersion: String

    public init(
        model: String? = nil,
        vendor: String? = nil,
        unknown1: UInt64 = 1,
        unknown2: String = "1",
        packageName: String = TVProtocol.serviceName,
        appVersion: String = "1.0.0"
    ) {
        self.model = model
        self.vendor = vendor
        self.unknown1 = unknown1
        self.unknown2 = unknown2
        self.packageName = packageName
        self.appVersion = appVersion
    }

    /// The fields the pinned client actually sends: `unknown1`, `unknown2`, `package_name`,
    /// `app_version` (proto3 defaults are not serialized, so `model`/`vendor` are omitted
    /// unless a caller supplies them).
    public var fields: [TVWireField] {
        var fields: [TVWireField] = []
        if let model { fields.append(TVProtobuf.stringField(1, model)) }
        if let vendor { fields.append(TVProtobuf.stringField(2, vendor)) }
        fields.append(TVProtobuf.varintField(3, unknown1))
        fields.append(TVProtobuf.stringField(4, unknown2))
        fields.append(TVProtobuf.stringField(5, packageName))
        fields.append(TVProtobuf.stringField(6, appVersion))
        return fields
    }
}

/// What the iPad sends on the remote port. Each case is exactly one `RemoteMessage` field.
public enum TVOutgoingRemote: Equatable, Sendable {
    case configure(supported: TVFeature, deviceInfo: TVDeviceInfo)
    case setActive(TVFeature)
    case pingResponse(val1: Int32)
    case key(TVKeycode, direction: TVKeyDirection)
    case imeBatchEdit(imeCounter: Int32, fieldCounter: Int32, text: String)
}

/// What the TV sends on the remote port.
public enum TVIncomingRemote: Equatable, Sendable {
    case configure(supported: TVFeature, deviceInfo: TVDeviceInfo?)
    case setActive(UInt64)
    case pingRequest(val1: Int32, val2: Int32)
    case keyInject(key: TVKeycode?, direction: TVKeyDirection?)
    case imeBatchEdit(imeCounter: Int32, fieldCounter: Int32)
    case imeShowRequest(fields: [TVWireField])
    case imeKeyInject(fields: [TVWireField])
    case start(started: Bool)
    case volumeLevel(fields: [TVWireField])
    case remoteError(fields: [TVWireField])
    case undecodable(fields: [TVWireField])
}

public enum TVRemoteWire {
    /// Encode and frame one outgoing `RemoteMessage`.
    public static func encoded(_ outgoing: TVOutgoingRemote) -> Data {
        TVFrame.encoded(fields(for: outgoing))
    }

    public static func fields(for outgoing: TVOutgoingRemote) -> [TVWireField] {
        switch outgoing {
        case .configure(let supported, let deviceInfo):
            return [
                TVProtobuf.messageField(1, [
                    TVProtobuf.varintField(1, UInt64(supported.rawValue)),
                    TVProtobuf.messageField(2, deviceInfo.fields),
                ]),
            ]
        case .setActive(let active):
            return [TVProtobuf.messageField(2, [TVProtobuf.varintField(1, UInt64(active.rawValue))])]
        case .pingResponse(let val1):
            return [TVProtobuf.messageField(9, [TVProtobuf.varintField(1, UInt64(bitPattern: Int64(val1)))])]
        case .key(let keycode, let direction):
            return [
                TVProtobuf.messageField(10, [
                    TVProtobuf.varintField(1, UInt64(bitPattern: Int64(keycode.rawValue))),
                    TVProtobuf.varintField(2, UInt64(bitPattern: Int64(direction.rawValue))),
                ]),
            ]
        case .imeBatchEdit(let imeCounter, let fieldCounter, let text):
            // `remote.py send_text`: start and end are `len(text) - 1` in the protocol's
            // UTF-16 counting; the value itself is sent as UTF-8 so Unicode is preserved.
            let cursor = UInt64(max(0, text.utf16.count - 1))
            return [
                TVProtobuf.messageField(21, [
                    TVProtobuf.varintField(1, UInt64(bitPattern: Int64(imeCounter))),
                    TVProtobuf.varintField(2, UInt64(bitPattern: Int64(fieldCounter))),
                    TVProtobuf.messageField(3, [
                        TVProtobuf.varintField(1, 1),
                        TVProtobuf.messageField(2, [
                            TVProtobuf.varintField(1, cursor),
                            TVProtobuf.varintField(2, cursor),
                            TVProtobuf.stringField(3, text),
                        ]),
                    ]),
                ]),
            ]
        }
    }

    /// Decode one framed `RemoteMessage`. Unknown/unlisted fields come back as
    /// `.undecodable(fields:)` with the raw fields preserved, never as a crash.
    public static func decode(_ message: Data) -> TVIncomingRemote {
        guard let fields = TVProtobuf.decode(message) else {
            return .undecodable(fields: [])
        }
        if let configure = TVProtobuf.nested(fields, 1) {
            let supported = TVFeature(rawValue: UInt32(truncatingIfNeeded: TVProtobuf.varint(configure, 1) ?? 0))
            var deviceInfo: TVDeviceInfo?
            if let infoFields = TVProtobuf.nested(configure, 2) {
                deviceInfo = TVDeviceInfo(
                    model: TVProtobuf.string(infoFields, 1),
                    vendor: TVProtobuf.string(infoFields, 2),
                    unknown1: TVProtobuf.varint(infoFields, 3) ?? 1,
                    unknown2: TVProtobuf.string(infoFields, 4) ?? "1",
                    packageName: TVProtobuf.string(infoFields, 5) ?? TVProtocol.serviceName,
                    appVersion: TVProtobuf.string(infoFields, 6) ?? "1.0.0"
                )
            }
            return .configure(supported: supported, deviceInfo: deviceInfo)
        }
        if let setActive = TVProtobuf.nested(fields, 2), let active = TVProtobuf.varint(setActive, 1) {
            return .setActive(active)
        }
        if let ping = TVProtobuf.nested(fields, 8) {
            let val1 = TVProtobuf.varint(ping, 1) ?? 0
            let val2 = TVProtobuf.varint(ping, 2) ?? 0
            return .pingRequest(
                val1: Int32(truncatingIfNeeded: val1),
                val2: Int32(truncatingIfNeeded: val2)
            )
        }
        if let inject = TVProtobuf.nested(fields, 10) {
            return .keyInject(
                key: TVProtobuf.varint(inject, 1).map { TVKeycode(rawValue: Int32(truncatingIfNeeded: $0)) } ?? nil,
                direction: TVProtobuf.varint(inject, 2).map { TVKeyDirection(rawValue: Int32(truncatingIfNeeded: $0)) } ?? nil
            )
        }
        if let batch = TVProtobuf.nested(fields, 21) {
            let imeCounter = TVProtobuf.varint(batch, 1) ?? 0
            let fieldCounter = TVProtobuf.varint(batch, 2) ?? 0
            return .imeBatchEdit(
                imeCounter: Int32(truncatingIfNeeded: imeCounter),
                fieldCounter: Int32(truncatingIfNeeded: fieldCounter)
            )
        }
        if let show = TVProtobuf.nested(fields, 22) { return .imeShowRequest(fields: show) }
        if let inject = TVProtobuf.nested(fields, 20) { return .imeKeyInject(fields: inject) }
        if let start = TVProtobuf.nested(fields, 40) {
            return .start(started: (TVProtobuf.varint(start, 1) ?? 0) != 0)
        }
        if let volume = TVProtobuf.nested(fields, 50) {
            return .volumeLevel(fields: volume)
        }
        if let error = TVProtobuf.nested(fields, 3) {
            return .remoteError(fields: error)
        }
        return .undecodable(fields: fields)
    }
}

// MARK: - Session reducer shared by the client and dependency-free CI tests

public enum TVConnectionState: Equatable, Sendable {
    case fresh, pairing, connecting, connected, reconnecting, localNetworkDenied
    case unavailable(String)
}
public enum TVPowerState: Equatable, Sendable { case unknown, off, on }
public enum TVTextEntryAvailability: Equatable, Sendable {
    case unavailable(reason: String)
    case available(imeCounter: Int32, fieldCounter: Int32)
}

public struct TVSession: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var connection: TVConnectionState = .fresh
    public private(set) var power: TVPowerState = .unknown
    public private(set) var pendingPower = false
    public private(set) var requestedFeatures: TVFeature
    public private(set) var supportedFeatures: TVFeature = []
    public private(set) var activeFeatures: TVFeature = []
    public private(set) var imeCounter: Int32?
    public private(set) var fieldCounter: Int32?
    public private(set) var activeFieldCounter: Int32?
    public private(set) var fieldSupported = false
    public private(set) var heldKeys: Set<TVKeycode> = []
    public private(set) var deviceInfo: TVDeviceInfo?
    public private(set) var lastFailure: TVWireFailure?

    public init(requestedFeatures: TVFeature = .requested) { self.requestedFeatures = requestedFeatures }

    public var textEntryAvailable: Bool {
        connection == .connected && activeFeatures.contains(.ime) && fieldSupported
            && imeCounter != nil && activeFieldCounter != nil && fieldCounter == activeFieldCounter
    }
    public func belongs(to generation: UInt64) -> Bool { self.generation == generation }

    private mutating func reset(_ state: TVConnectionState) {
        generation &+= 1
        connection = state
        power = .unknown
        pendingPower = false
        supportedFeatures = []
        activeFeatures = []
        imeCounter = nil
        fieldCounter = nil
        activeFieldCounter = nil
        fieldSupported = false
        heldKeys = []
        deviceInfo = nil
        lastFailure = nil
    }
    public mutating func beginPairing() { reset(.pairing) }
    public mutating func beginConnect() { reset(.connecting) }
    public mutating func beginReconnect() { reset(.reconnecting) }
    public mutating func markUnavailable(_ reason: String) {
        reset(.unavailable(reason))
        lastFailure = .unexpectedMessage(reason)
    }
    public mutating func markLocalNetworkDenied() { reset(.localNetworkDenied) }
    public mutating func markConnected() { connection = .connected }

    public mutating func noteRemoteConfigure(supported: TVFeature, deviceInfo: TVDeviceInfo?) -> TVOutgoingRemote? {
        guard connection == .connecting || connection == .reconnecting || connection == .connected else { return nil }
        supportedFeatures = supported
        activeFeatures = requestedFeatures.intersection(supported)
        guard activeFeatures.contains(.key) else {
            markUnavailable("The TV service does not support remote keys.")
            return nil
        }
        self.deviceInfo = deviceInfo
        return .configure(supported: activeFeatures, deviceInfo: TVDeviceInfo())
    }
    public mutating func noteRemoteSetActive() -> TVOutgoingRemote? {
        guard connection == .connecting || connection == .reconnecting || connection == .connected else { return nil }
        return .setActive(activeFeatures)
    }
    public mutating func notePingRequest(val1: Int32, val2: Int32) -> TVOutgoingRemote? {
        guard connection == .connecting || connection == .reconnecting || connection == .connected else { return nil }
        return .pingResponse(val1: val1)
    }

    /// A field announcement alone cannot authorize text; the same field must supply IME counters.
    public mutating func noteIMEField(counter: Int32, active: Bool, supported: Bool) {
        guard activeFeatures.contains(.ime), active, supported, counter >= 0 else {
            markTextEntryUnsupported(reason: "No supported active TV text field.")
            return
        }
        if activeFieldCounter != counter || !fieldSupported {
            imeCounter = nil
            fieldCounter = nil
        }
        activeFieldCounter = counter
        fieldSupported = true
    }
    public mutating func noteIMEBatchEdit(imeCounter: Int32, fieldCounter: Int32) {
        guard connection == .connected, activeFeatures.contains(.ime),
              fieldSupported, activeFieldCounter == fieldCounter else {
            self.imeCounter = nil
            self.fieldCounter = nil
            return
        }
        self.imeCounter = imeCounter
        self.fieldCounter = fieldCounter
    }
    public mutating func markTextEntryUnsupported(reason: String) {
        imeCounter = nil
        fieldCounter = nil
        activeFieldCounter = nil
        fieldSupported = false
    }

    public mutating func pressKey(_ keycode: TVKeycode) -> TVOutgoingRemote? {
        guard connection == .connected, activeFeatures.contains(.key), !heldKeys.contains(keycode) else { return nil }
        heldKeys.insert(keycode)
        return .key(keycode, direction: .startLong)
    }
    public mutating func releaseKey(_ keycode: TVKeycode) -> TVOutgoingRemote? {
        guard heldKeys.remove(keycode) != nil, connection == .connected, activeFeatures.contains(.key) else { return nil }
        return .key(keycode, direction: .endLong)
    }
    public mutating func tapKey(_ keycode: TVKeycode) -> TVOutgoingRemote? {
        guard connection == .connected, activeFeatures.contains(.key) else { return nil }
        return .key(keycode, direction: .short)
    }
    public mutating func textFrame(_ text: String) -> TVOutgoingRemote? {
        guard textEntryAvailable, !text.isEmpty, text.utf8.count <= TVLimits.maxFieldBytes / 2,
              let imeCounter, let fieldCounter else { return nil }
        return .imeBatchEdit(imeCounter: imeCounter, fieldCounter: fieldCounter, text: text)
    }
    public mutating func requestPowerToggle() -> TVOutgoingRemote? {
        guard connection == .connected, activeFeatures.contains(.key),
              activeFeatures.contains(.power), !pendingPower else { return nil }
        pendingPower = true
        return .key(.power, direction: .short)
    }
    public mutating func noteRemoteStart(started: Bool) {
        power = started ? .on : .off
        pendingPower = false
    }
    public mutating func expirePendingPower() {
        guard pendingPower else { return }
        pendingPower = false
        power = .unknown
    }
    public mutating func releaseAllHeldKeys() -> [TVOutgoingRemote] {
        let keys = heldKeys.sorted { $0.rawValue < $1.rawValue }
        heldKeys = []
        guard connection == .connected, activeFeatures.contains(.key) else { return [] }
        return keys.map { .key($0, direction: .endLong) }
    }
}
