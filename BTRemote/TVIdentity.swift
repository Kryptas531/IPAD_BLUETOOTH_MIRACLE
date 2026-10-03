//
//  TVIdentity.swift
//  BTRemote
//
//  SPEC §7.3 B/D — iPad-side client identity for the direct Wi-Fi TV target
//  (Android TV Remote v2). Reference-only sources, inspected 2026-10-03, no upstream
//  source copied or translated (clean-room; upstream licensing stays untouched):
//  tronikos/androidtvremote2 @ b09f21432ba33e42536215a8f41641d801cf6a2c
//  (certificate_generator.py, pairing.py lines 95-130).
//
//  Provides: the Keychain-persisted RSA-2048 key pair + self-signed X.509 client
//  certificate for Network.framework mutual TLS, RSA key extraction from the TV's
//  server certificate, the SHA-256 pairing secret computation (client modulus+exponent,
//  server modulus+exponent, PIN last-2-bytes, with 6-hex-char validation and
//  hash-first-byte == first-PIN-byte check), and the saved TV association record
//  (host / label / server-certificate SHA-256 pin) — written only after the caller's
//  pairing ACK. All secrets stay in the Keychain; nothing logs a key, certificate,
//  PIN or typed text; nothing touches the Windows helper's credential records
//  (those live in WindowsForeground.swift under "io.github.jqssun.btremote.windows-foreground"
//  and are not read or written here).
//
//  Concurrency (Swift 6): TVIdentityMaterial carries Security/CF objects, so it is a
//  narrow @unchecked Sendable wrapper — the material is created once and handed to one
//  owner (the future TV transport / Network.framework session), never shared mutably,
//  and nothing in this file holds global mutable state. All APIs are module-visible so
//  the transport worker and a future macOS no-network smoke test can use them.
//  Compilation is a CI gate: this host is Windows with no Swift toolchain.
//

import Foundation
import CryptoKit
import Security

// MARK: - Types

/// The two integers of an RSA public key as raw big-endian bytes, exactly as the
/// §7.3 B pairing secret needs them: `modulus` is the positive magnitude with the
/// DER sign octet stripped (RSA-2048: 256 bytes), `exponent` is the minimal
/// big-endian form of 65537, i.e. `01 00 01` (3 bytes).
struct TVRSAPublicKeyMaterial: Equatable, Sendable {
    var modulus: Data
    var exponent: Data
}

/// Everything the transport needs from `TVIdentityStore.loadOrCreate()`: a usable
/// `SecIdentity` (private key + matching self-signed certificate) for mutual TLS,
/// the client certificate DER, and the client's RSA public key material.
struct TVIdentityMaterial: @unchecked Sendable {
    let identity: SecIdentity
    let clientCertificateDER: Data
    let clientPublicKey: TVRSAPublicKeyMaterial
}

/// The saved TV association: selected host + label, and the SHA-256 pin of the
/// server certificate captured during pairing. This is pairing-bound trust
/// material, not a blanket TLS trust setting (§7.3 B/D).
struct TVSavedPairing: Codable, Equatable, Sendable {
    var host: String
    var label: String
    var serverCertificateSHA256: Data
}

/// Everything that can go wrong in the TV identity / pairing flow. No case carries
/// secret material, a PIN or typed text.
enum TVIdentityError: Error, Equatable {
    /// Hard failure of a Security/Keychain API (bad `OSStatus`, e.g. an access denial).
    /// Deliberately distinct from "item not found": an access denial must never be
    /// answered by generating a new key pair, which would silently destroy the
    /// existing paired client identity (§7.3 B).
    case keychain(OSStatus)
    /// The server certificate could not be parsed, its key is not RSA, or its public
    /// exponent is not 65537 ("reject unsupported RSA/key").
    case invalidCertificate
    /// The pairing PIN is not exactly 6 hex characters.
    case invalidPIN
    /// SHA-256 binding check failed (hash first byte != PIN first byte): wrong PIN.
    /// The existing saved pairing is left untouched; the caller re-reads a fresh
    /// code off the TV ("re-pair required", §7.3 B).
    case pairingHashMismatch
    /// The saved pairing belongs to a different host / the presented server
    /// certificate does not match the saved pin ("identity changed / re-pair
    /// required"). Nothing is replaced or removed implicitly — `forgetPairing()` is
    /// an explicit caller action.
    case rePairRequired
    /// A TV pairing record already exists for a different host; the saved server
    /// certificate pin must not be silently replaced — `forgetPairing()` first.
    case existingPairingConflict
    /// An offline no-network smoke check did not hold.
    case selfCheckFailed
}

/// The outcome of the module-visible offline self-check (no network, no TV).
struct TVIdentitySelfCheckReport: Equatable, Sendable {
    let signatureVerified: Bool
    let publicKeyVerified: Bool
    let identityVerified: Bool
    let pairingVectorVerified: Bool
}

// MARK: - Small DER support (private names; TVWire keeps its own types separate)

private struct TVIdentityTLV {
    let tag: UInt8
    let content: Data
}

private enum TVIdentityDER {
    /// One DER TLV: `tag + definite length + content`. The generated certificate's
    /// longest content is ~650 bytes, so only short form and the 0x81/0x82 long
    /// forms are needed; anything larger is out of scope and never produced.
    static func encoded(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 128 {
            out.append(UInt8(count))
        } else if count < 256 {
            out.append(contentsOf: [0x81, UInt8(count)])
        } else {
            out.append(contentsOf: [0x82, UInt8(count >> 8), UInt8(count & 0xFF)])
        }
        out.append(content)
        return out
    }

    static func sequence(_ parts: [Data]) -> Data {
        var body = Data()
        for part in parts { body.append(part) }
        return encoded(tag: 0x30, body)
    }

    /// DER INTEGER holding a positive number given as big-endian magnitude: leading
    /// zero bytes are stripped (minimal encoding) and a 0x00 sign octet is prepended
    /// when the top bit is set — so 65537 stays `01 00 01`.
    static func positiveInteger(from magnitude: [UInt8]) -> Data {
        var bytes = [UInt8]()
        var index = 0
        while index < magnitude.count, magnitude[index] == 0x00 { index += 1 }
        bytes = Array(magnitude[index...])
        if bytes.isEmpty { bytes = [0x00] }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return encoded(tag: 0x02, Data(bytes))
    }

    /// Parse one TLV from the start of a byte buffer.
    static func parseTLV(_ data: Data) throws -> (tlv: TVIdentityTLV, remainder: Data) {
        guard data.count >= 2 else { throw TVIdentityError.invalidCertificate }
        var pos = data.startIndex
        let tag = data[pos]
        pos += 1
        let lengthByte = data[pos]
        pos += 1
        let length: Int
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else if lengthByte == 0x81 {
            guard data.count - pos >= 1 else { throw TVIdentityError.invalidCertificate }
            length = Int(data[pos])
            pos += 1
        } else if lengthByte == 0x82 {
            guard data.count - pos >= 2 else { throw TVIdentityError.invalidCertificate }
            length = (Int(data[pos]) << 8) | Int(data[pos + 1])
            pos += 2
        } else {
            throw TVIdentityError.invalidCertificate // unsupported length form
        }
        guard data.count - pos >= length else { throw TVIdentityError.invalidCertificate }
        let content = data.subdata(in: pos..<(pos + length))
        let remainder = data.subdata(in: (pos + length)..<data.count)
        return (TVIdentityTLV(tag: tag, content: content), remainder)
    }
}

/// Parse a DER `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`
/// (the format `SecKeyCopyExternalRepresentation` returns for RSA keys). The modulus
/// loses a leading DER sign octet; the exponent must be exactly `01 00 01` (65537,
/// minimal big-endian) or the key is rejected as unsupported.
private func tvParseRSAPublicKey(_ der: Data) throws -> TVRSAPublicKeyMaterial {
    let (outer, remainder) = try TVIdentityDER.parseTLV(der)
    guard remainder.isEmpty, outer.tag == 0x30 else { throw TVIdentityError.invalidCertificate }
    let (modulusTLV, afterModulus) = try TVIdentityDER.parseTLV(outer.content)
    let (exponentTLV, afterExponent) = try TVIdentityDER.parseTLV(afterModulus)
    guard modulusTLV.tag == 0x02,
          exponentTLV.tag == 0x02,
          afterExponent.isEmpty
    else { throw TVIdentityError.invalidCertificate }
    // Strip a leading DER sign octet from the modulus.
    var modulusBytes = [UInt8](modulusTLV.content)
    var start = 0
    while start < modulusBytes.count, modulusBytes[start] == 0x00 { start += 1 }
    guard start < modulusBytes.count else { throw TVIdentityError.invalidCertificate }
    let modulus = Data(modulusBytes[start...])
    guard exponentTLV.content == Data([0x01, 0x00, 0x01]) else {
        throw TVIdentityError.invalidCertificate // only RSA with 65537 is supported
    }
    return TVRSAPublicKeyMaterial(modulus: modulus, exponent: Data([0x01, 0x00, 0x01]))
}

// MARK: - TV identity store (keychain-backed RSA-2048 + self-signed X.509)

/// Stateless namespace for the TV client identity; no shared mutable state.
enum TVIdentityStore {
    /// Independent TV-only keychain namespace — never the Windows helper records.
    static let privateKeyTag = Data("tv-remote-rsa-2048-private".utf8)
    static let certificateLabel = "tv-remote-client-cert"
    static let pairingService = "tv-remote-pairing"
    static let pairingAccount = "selected-tv"

    /// Fixed identity label inside the self-signed certificate. The reference used
    /// the device hostname; this client has no hostname, and the TV binds trust to
    /// the RSA key material, not the subject name.
    static let clientCommonName = "BTRemote"

    /// RSA public exponent 65537 as minimal big-endian bytes.
    static let rsaExponent = Data([0x01, 0x00, 0x01])

    /// Loads the persisted TV key pair + certificate, or creates them on first use,
    /// and returns a usable `SecIdentity` with the client RSA public key material.
    ///
    /// The private key is persisted with `kSecAttrIsPermanent` +
    /// `kSecAttrApplicationTag` (the documented way to store an RSA key); the
    /// self-signed certificate is added as a `kSecClassCertificate` item using the
    /// matching public key, and the usable `SecIdentity` is obtained by querying
    /// `kSecClassIdentity` and matching the exact saved certificate — because
    /// `SecIdentityCreateWithCertificate` is macOS-only and is not used here.
    /// A stored key is only created fresh when the item is genuinely missing; any
    /// other `OSStatus` (e.g. access denial) throws instead of silently regenerating
    /// the private key (§7.3 B).
    static func loadOrCreate() throws -> TVIdentityMaterial {
        var keyItem: CFTypeRef?
        let keyStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
            kSecReturnRef as String: kCFBooleanTrue!,
        ] as CFDictionary, &keyItem)

        switch keyStatus {
        case errSecSuccess:
            guard let keyItem, CFGetTypeID(keyItem) == SecKeyGetTypeID() else {
                throw TVIdentityError.rePairRequired // stored key unusable for RSA
            }
            let privateKey = keyItem as! SecKey
            guard SecKeyCopyPublicKey(privateKey) != nil else { throw TVIdentityError.rePairRequired }
            var certItem: CFTypeRef?
            let certStatus = SecItemCopyMatching([
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: certificateLabel,
                kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
                kSecReturnData as String: kCFBooleanTrue!,
            ] as CFDictionary, &certItem)
            let clientCertificateDER: Data
            if certStatus == errSecSuccess, let data = certItem as? Data { clientCertificateDER = data }
            else if certStatus == errSecItemNotFound {
                // A failed first attempt may have saved the key but not its certificate.
                // Finish only an unpaired identity, using that SAME key. Never rotate a paired identity.
                guard try loadPairing() == nil else { throw TVIdentityError.rePairRequired }
                clientCertificateDER = try makeCertificate(privateKey: privateKey)
                try storeClientCertificate(clientCertificateDER)
            } else { throw TVIdentityError.keychain(certStatus) }
            try verifyClientCertificate(clientCertificateDER, privateKey: privateKey)
            let identity = try matchingIdentity(certificateDER: clientCertificateDER)
            // Confirm the identity really pairs *our* stored key with *our* stored
            // certificate (exact match, §7.3 B).
            var identityCertificate: SecCertificate?
            let copyStatus = SecIdentityCopyCertificate(identity, &identityCertificate)
            guard copyStatus == errSecSuccess,
                  let identityCert = identityCertificate,
                  SecCertificateCopyData(identityCert) as Data == clientCertificateDER
            else { throw TVIdentityError.rePairRequired }
            let clientPublicKey = try extractRSAModulusAndExponent(fromServerCertificate: clientCertificateDER)
            return TVIdentityMaterial(identity: identity,
                                      clientCertificateDER: clientCertificateDER,
                                      clientPublicKey: clientPublicKey)

        case errSecItemNotFound:
            // Nothing stored yet: create the RSA-2048 key pair.
            var securityError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey([
                kSecClass as String: kSecClassKey,
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: NSNumber(value: 2048),
                kSecPrivateKeyAttrs as String: [
                    kSecAttrApplicationTag as String: privateKeyTag,
                    kSecAttrIsPermanent as String: true,
                    kSecAttrLabel as String: "tv-remote-rsa-2048",
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ],
                kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
            ] as CFDictionary, &securityError) else {
                throw TVIdentityError.keychain(
                    tvIdentityErrorStatus(securityError))
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw TVIdentityError.selfCheckFailed // RSA-2048 without a public half
            }
            guard let rsaPublicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &securityError) else {
                throw TVIdentityError.keychain(
                    tvIdentityErrorStatus(securityError))
            }
            let clientPublicKey = try tvParseRSAPublicKey(rsaPublicKeyDER as Data)

            let certificateDER = try makeCertificate(privateKey: privateKey)

            // Persist key + certificate; then query kSecClassIdentity so the keychain
            // pairs them (matching public key) into the actual SecIdentity to use.
            try storeClientCertificate(certificateDER)
            try verifyClientCertificate(certificateDER, privateKey: privateKey)
            let identity = try matchingIdentity(certificateDER: certificateDER)
            var newIdentityCertificate: SecCertificate?
            let copyStatus = SecIdentityCopyCertificate(identity, &newIdentityCertificate)
            guard copyStatus == errSecSuccess,
                  let newCert = newIdentityCertificate,
                  SecCertificateCopyData(newCert) as Data == certificateDER
            else { throw TVIdentityError.rePairRequired }
            return TVIdentityMaterial(identity: identity,
                                      clientCertificateDER: certificateDER,
                                      clientPublicKey: clientPublicKey)

        default:
            // Any other OSStatus (e.g. errSecAuthFailed / access denied): report it —
            // never regenerate the private key on a denial.
            throw TVIdentityError.keychain(keyStatus)
        }
    }

    private static func storeClientCertificate(_ der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TVIdentityError.invalidCertificate
        }
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
            kSecValueRef as String: certificate,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw TVIdentityError.keychain(status) }
    }

    // Apple DTS: identity attribute queries can fail (r.144152660). Enumerate references
    // and select OUR exact certificate, never the first unrelated identity.
    // https://developer.apple.com/forums/thread/773777
    private static func matchingIdentity(certificateDER: Data) throws -> SecIdentity {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { throw TVIdentityError.keychain(status) }
        guard let identities = result as? [SecIdentity] else { throw TVIdentityError.keychain(errSecDecode) }
        for identity in identities {
            var certificate: SecCertificate?
            let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
            guard copyStatus == errSecSuccess else { throw TVIdentityError.keychain(copyStatus) }
            if let certificate, SecCertificateCopyData(certificate) as Data == certificateDER { return identity }
        }
        throw TVIdentityError.keychain(errSecItemNotFound)
    }

    static func verifyClientCertificate(_ der: Data, privateKey: SecKey) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let certificateKey = SecCertificateCopyKey(certificate),
              let publicKey = SecKeyCopyPublicKey(privateKey) else { throw TVIdentityError.invalidCertificate }
        var error: Unmanaged<CFError>?
        guard let storedBits = SecKeyCopyExternalRepresentation(publicKey, &error),
              let certificateBits = SecKeyCopyExternalRepresentation(certificateKey, &error),
              storedBits as Data == certificateBits as Data else { throw TVIdentityError.rePairRequired }
    }

    /// The same certificate generator used by the Keychain path, also exercised on macOS
    /// with an ephemeral key so tests need no signing identity or personal keychain.
    static func makeCertificate(privateKey: SecKey) throws -> Data {
        var securityError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let rsaPublicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &securityError) else {
            throw TVIdentityError.invalidCertificate
        }
        // Self-sign an X.509 certificate for the key (reference
        // certificate_generator.py: CN + RSA, SHA-256, PKCS#1 v1.5).
        let now = Date()
        let notBefore = now.addingTimeInterval(-86_400) // tolerate clock skew
        let notAfter = now.addingTimeInterval(3650 * 86_400) // 10 years, both < 2050
        var serialBytes = [UInt8](repeating: 0, count: 8)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        guard randomStatus == errSecSuccess else { throw TVIdentityError.keychain(randomStatus) }

        let name = Data(TVIdentityDER.sequence([
            TVIdentityDER.encoded(tag: 0x31, TVIdentityDER.sequence([
                Data([0x06, 0x03, 0x55, 0x04, 0x03]), // OID 2.5.4.3 commonName
                Data([0x0C, UInt8(clientCommonName.utf8.count)]) + Data(clientCommonName.utf8), // UTF8String
            ])),
        ]))
        let spki = TVIdentityDER.sequence([
            TVIdentityDER.sequence([
                Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), // rsaEncryption
                Data([0x05, 0x00]), // NULL parameters
            ]),
            TVIdentityDER.encoded(tag: 0x03, Data([0x00]) + (rsaPublicKeyDER as Data)), // BIT STRING
        ])
        let extensions = TVIdentityDER.encoded(tag: 0xA3, TVIdentityDER.sequence([
            TVIdentityDER.sequence([
                Data([0x06, 0x03, 0x55, 0x1D, 0x13]), // basicConstraints, not critical as in the reference
                TVIdentityDER.encoded(tag: 0x04, Data([0x30, 0x06, 0x01, 0x01, 0xFF, 0x02, 0x01, 0x00])),
            ]),
        ]))
        let tbs = TVIdentityDER.sequence([
            Data([0xA0, 0x03, 0x02, 0x01, 0x02]), // version v3
            TVIdentityDER.positiveInteger(from: serialBytes), // random positive serial
            Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]), // sha256WithRSAEncryption + NULL
            name, // issuer == subject (self-signed)
            TVIdentityDER.sequence([
                tvIdentityTimeTLV(notBefore),
                tvIdentityTimeTLV(notAfter),
            ]),
            name,
            spki,
            extensions,
        ])
        guard let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &securityError) else {
            throw TVIdentityError.keychain(
                tvIdentityErrorStatus(securityError))
        }
        let certificateDER = Data(TVIdentityDER.sequence([
            tbs,
            Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00]),
            Data([0x03, 0x82, 0x01, 0x01, 0x00]) + (signature as Data), // BIT STRING, 256-byte RSA signature
        ]))

        return certificateDER
    }

    static func verifyCertificateSignature(_ der: Data) throws -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(cert) else { throw TVIdentityError.invalidCertificate }
        let (outer, trailing) = try TVIdentityDER.parseTLV(der)
        guard outer.tag == 0x30, trailing.isEmpty else { throw TVIdentityError.invalidCertificate }
        let (tbs, rest) = try TVIdentityDER.parseTLV(outer.content)
        let (_, signaturePart) = try TVIdentityDER.parseTLV(rest)
        let (signature, end) = try TVIdentityDER.parseTLV(signaturePart)
        guard tbs.tag == 0x30, signature.tag == 0x03, signature.content.first == 0,
              end.isEmpty else { throw TVIdentityError.invalidCertificate }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
            TVIdentityDER.encoded(tag: 0x30, tbs.content) as CFData,
            Data(signature.content.dropFirst()) as CFData, &error)
    }

    static func verifyPeerCertificate(_ der: Data, pairing: TVSavedPairing) throws {
        guard pairing.serverCertificateSHA256.count == 32,
              Data(SHA256.hash(data: der)) == pairing.serverCertificateSHA256 else {
            throw TVIdentityError.rePairRequired
        }
    }

    /// Extracts the RSA modulus/exponent a TV presented: parses the server
    /// certificate and its RSA public key ("static/server method"). Rejects
    /// malformed, non-RSA or non-65537 keys.
    static func extractRSAModulusAndExponent(fromServerCertificate der: Data) throws -> TVRSAPublicKeyMaterial {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TVIdentityError.invalidCertificate
        }
        guard let key = SecCertificateCopyKey(certificate) else {
            throw TVIdentityError.invalidCertificate // not an RSA key
        }
        var error: Unmanaged<CFError>?
        guard let blob = SecKeyCopyExternalRepresentation(key, &error) else {
            throw TVIdentityError.invalidCertificate
        }
        return try tvParseRSAPublicKey(blob as Data)
    }

    /// §7.3 B pairing secret: `SHA256(clientModulus || clientExponent ||
    /// serverModulus || serverExponent || PIN-last-2-bytes)` where the PIN is 6 hex
    /// characters and the hash's first byte must equal the PIN's first byte
    /// (reference `pairing.py` lines 95-130). A wrong PIN throws and leaves any
    /// existing saved pairing untouched.
    static func pairingSecret(code: String,
                              client: TVRSAPublicKeyMaterial,
                              server: TVRSAPublicKeyMaterial) throws -> Data {
        guard code.count == 6 else { throw TVIdentityError.invalidPIN }
        var pinBytes = [UInt8]()
        for position in stride(from: 0, to: 6, by: 2) {
            let index = code.index(code.startIndex, offsetBy: position)
            guard let byte = UInt8(String(code[index..<code.index(index, offsetBy: 2)]), radix: 16) else {
                throw TVIdentityError.invalidPIN
            }
            pinBytes.append(byte)
        }
        var material = Data()
        material.append(client.modulus)
        material.append(client.exponent)
        material.append(server.modulus)
        material.append(server.exponent)
        material.append(contentsOf: [pinBytes[1], pinBytes[2]])
        let digest = Data(SHA256.hash(data: material))
        guard digest.first == pinBytes[0] else { throw TVIdentityError.pairingHashMismatch }
        return digest
    }

    /// Reads the saved TV association (host / label / server-certificate SHA-256
    /// pin). `nil` means nothing is saved yet (item-not-found); any other keychain
    /// failure throws, so a denial is never mistaken for "no pairing".
    static func loadPairing() throws -> TVSavedPairing? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingService,
            kSecAttrAccount as String: pairingAccount,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
            kSecReturnData as String: kCFBooleanTrue!,
        ] as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let decoded = try? JSONDecoder().decode(TVSavedPairing.self, from: data)
            else { throw TVIdentityError.keychain(errSecDecode) }
            return decoded
        case errSecItemNotFound:
            return nil
        default:
            throw TVIdentityError.keychain(status)
        }
    }

    /// Persists the selected TV (host / label) and the SHA-256 pin of its server
    /// certificate in the dedicated TV-only generic-password record. Call this only
    /// after the caller completed pairing (valid PIN + the TV's secret ACK). A host
    /// change never silently replaces a saved pin (`existingPairingConflict` — the
    /// caller must `forgetPairing()` explicitly); the same host may re-pair.
    static func savePairing(host: String, certificateDER: Data, label: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw TVIdentityError.invalidCertificate }
        guard let existing = try loadPairing() else {
            let record = TVSavedPairing(host: trimmedHost,
                                        label: label,
                                        serverCertificateSHA256: Data(SHA256.hash(data: certificateDER)))
            let data = try JSONEncoder().encode(record)
            let status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: pairingService,
                kSecAttrAccount as String: pairingAccount,
                kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ] as CFDictionary, nil)
            guard status == errSecSuccess else { throw TVIdentityError.keychain(status) }
            return
        }
        // An address may change while the selected TV identity stays the same.
        // A different peer certificate always requires explicit forget/re-pair.
        guard existing.serverCertificateSHA256 == Data(SHA256.hash(data: certificateDER)) else {
            throw TVIdentityError.existingPairingConflict
        }
        let record = TVSavedPairing(host: trimmedHost,
                                    label: label,
                                    serverCertificateSHA256: Data(SHA256.hash(data: certificateDER)))
        let data = try JSONEncoder().encode(record)
        let status = SecItemUpdate([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingService,
            kSecAttrAccount as String: pairingAccount,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ] as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
            ] as CFDictionary)
        guard status == errSecSuccess else { throw TVIdentityError.keychain(status) }
    }

    /// Explicit user recovery removes only TV-owned credentials, including a damaged
    /// client identity. Authentication failures never call this automatically.
    static func forgetPairing() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingService,
            kSecAttrAccount as String: pairingAccount,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TVIdentityError.keychain(status)
        }
        for query: [String: Any] in [
            [kSecClass as String: kSecClassCertificate,
             kSecAttrLabel as String: certificateLabel,
             kSecUseDataProtectionKeychain as String: kCFBooleanTrue!],
            [kSecClass as String: kSecClassKey,
             kSecAttrApplicationTag as String: privateKeyTag,
             kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
             kSecUseDataProtectionKeychain as String: kCFBooleanTrue!],
        ] {
            let deletion = SecItemDelete(query as CFDictionary)
            guard deletion == errSecSuccess || deletion == errSecItemNotFound else {
                throw TVIdentityError.keychain(deletion)
            }
        }
    }

    /// No-network check of the actual certificate generator and pairing vector.
    /// Keychain reuse and SecIdentity presentation still require the installed iPad test.
    static func runNoNetworkSelfCheck() throws -> TVIdentitySelfCheckReport {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw TVIdentityError.selfCheckFailed
        }
        let der = try makeCertificate(privateKey: key)
        try verifyClientCertificate(der, privateKey: key)
        guard let wrongKey = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, &error) else { throw TVIdentityError.selfCheckFailed }
        var mismatchRejected = false
        do { try verifyClientCertificate(der, privateKey: wrongKey) }
        catch TVIdentityError.rePairRequired { mismatchRejected = true }
        guard mismatchRejected else { throw TVIdentityError.selfCheckFailed }
        let signatureVerified = try verifyCertificateSignature(der)
        let extracted = try extractRSAModulusAndExponent(fromServerCertificate: der)
        let publicKeyVerified = extracted == (try tvParseRSAPublicKey(publicDER as Data))
        let client = TVRSAPublicKeyMaterial(modulus: Data([0x81, 0x02, 0x03]),
                                           exponent: Data([0x01, 0x00, 0x01]))
        let server = TVRSAPublicKeyMaterial(modulus: Data([0x91, 0x04, 0x05]),
                                           exponent: Data([0x01, 0x00, 0x01]))
        let secret = try pairingSecret(code: "84abcd", client: client, server: server)
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let pairingVectorVerified = hex == "84f12cb01e89d2f4244ae853de0c53379acbb037fa290acae56eb5debd067bce"
        guard signatureVerified, publicKeyVerified, pairingVectorVerified else {
            throw TVIdentityError.selfCheckFailed
        }
        return TVIdentitySelfCheckReport(signatureVerified: signatureVerified,
            publicKeyVerified: publicKeyVerified, identityVerified: false,
            pairingVectorVerified: pairingVectorVerified)
    }

}

/// DER time TLV: UTCTime for years before 2050, GeneralizedTime otherwise; both
/// written in UTC (reference certificate_generator.py uses datetimes in UTC).
private func tvIdentityTimeTLV(_ date: Date) -> Data {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    if let year = c.year, year < 2050 {
        let string = String(format: "%02d%02d%02d%02d%02d%02dZ",
                            year % 100, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return Data([0x17, 0x0D]) + Data(string.utf8) // UTCTime, 13 chars
    }
    let string = String(format: "%04d%02d%02d%02d%02d%02dZ",
                        c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    return Data([0x18, 0x0F]) + Data(string.utf8) // GeneralizedTime, 15 chars
}

private func tvIdentityErrorStatus(_ error: Unmanaged<CFError>?) -> OSStatus {
    guard let error else { return -1 }
    return OSStatus(truncatingIfNeeded: CFErrorGetCode(error.takeRetainedValue()))
}
