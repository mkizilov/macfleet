import CryptoKit
import Foundation
import Network
import os
import Security

/// SHA-256 of a host's certificate. A client pins this value: it trusts a host only when the host's certificate has
/// exactly this fingerprint, so no certificate authority is involved.
public struct HostFingerprint: Hashable, Codable, Sendable, CustomStringConvertible {
    /// 64 lowercase hexadecimal digits.
    public let hex: String

    public init(certificateDER: Data) {
        hex = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses "SHA256:" followed by 64 hexadecimal digits, the form `description` prints.
    public init?(string: String) {
        let prefix = "SHA256:"
        guard string.hasPrefix(prefix) else { return nil }
        let digits = string.dropFirst(prefix.count).lowercased()
        guard digits.count == 64, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        hex = digits
    }

    public var description: String {
        "SHA256:\(hex)"
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let fingerprint = HostFingerprint(string: string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\"\(string)\" is not a host fingerprint"
            ))
        }
        self = fingerprint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum RemoteIdentityError: Error, Equatable, Sendable {
    /// Identities are imported in memory only, so the keychain is never written. That import needs macOS 15 or later.
    case memoryOnlyImportRequiresMacOS15
    case importFailed(OSStatus)
    case certificateUnreadable
}

/// Loads the host's identity from a PKCS#12 bundle, the format openssl writes. The bundle holds the certificate and
/// its private key. Nothing is stored in the keychain.
enum RemoteHostIdentityImport {
    static func importIdentity(pkcs12: Data, passphrase: String) throws -> (identity: SecIdentity, fingerprint: HostFingerprint) {
        guard #available(macOS 15.0, *) else { throw RemoteIdentityError.memoryOnlyImportRequiresMacOS15 }
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let reference = entries.first?[kSecImportItemIdentity as String]
        else {
            throw RemoteIdentityError.importFailed(status)
        }
        let identity = reference as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw RemoteIdentityError.certificateUnreadable
        }
        let fingerprint = HostFingerprint(certificateDER: SecCertificateCopyData(certificate) as Data)
        return (identity, fingerprint)
    }
}

/// Reads a host's fingerprint from its identity bundle, so an operator can give it to clients. The identity itself is
/// discarded.
public enum RemoteIdentityReader {
    public static func fingerprint(pkcs12: Data, passphrase: String) throws -> HostFingerprint {
        try RemoteHostIdentityImport.importIdentity(pkcs12: pkcs12, passphrase: passphrase).fingerprint
    }
}

/// The certificate a TLS connection was offered, recorded by the verify block. A failed connection reads it, so it can
/// say which certificate was shown instead of only that the handshake failed.
final class FingerprintObservation: Sendable {
    private struct Seen: Sendable {
        var fingerprint: HostFingerprint?
        var rejection: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: Seen(fingerprint: nil, rejection: nil))

    var value: HostFingerprint? {
        lock.withLock { $0.fingerprint }
    }

    /// Why the pinned check refused the certificate, when it did. Nil when it accepted it or never ran.
    var rejection: String? {
        lock.withLock { $0.rejection }
    }

    func record(_ fingerprint: HostFingerprint?, rejection: String? = nil) {
        lock.withLock { $0 = Seen(fingerprint: fingerprint, rejection: rejection) }
    }
}

/// The client's check of the host's certificate during the TLS handshake. Trust comes only from the pin.
enum RemoteTrustPolicy {
    /// The fingerprint of the leaf certificate a peer presented, or nil when it presented none.
    static func leafFingerprint(_ trust: SecTrust) -> HostFingerprint? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return HostFingerprint(certificateDER: SecCertificateCopyData(leaf) as Data)
    }

    /// Accepts the peer only when its leaf certificate has the pinned fingerprint, and when the certificate itself
    /// passes a basic X.509 check (validity dates and signature) with no other anchor. The system trust store is not
    /// consulted.
    static func accepts(_ trust: SecTrust, pinned: HostFingerprint) -> Bool {
        rejection(trust, pinned: pinned) == nil
    }

    /// Why the peer's certificate is refused, or nil when it is accepted. A certificate that is not the pinned one is
    /// refused by fingerprint. A pinned certificate that fails the X.509 check, such as an expired one, is refused with the
    /// reason the check gave.
    static func rejection(_ trust: SecTrust, pinned: HostFingerprint) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return "the host presented no certificate"
        }
        guard leafFingerprint(trust) == pinned else {
            return "the certificate is not the pinned one"
        }
        var anchored: SecTrust?
        guard SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateBasicX509(), &anchored) == errSecSuccess,
              let anchored
        else {
            return "the certificate could not be checked"
        }
        SecTrustSetAnchorCertificates(anchored, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(anchored, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(anchored, &error) else {
            return error.map { CFErrorCopyDescription($0) as String } ?? "the certificate failed its checks"
        }
        return nil
    }
}

/// TLS 1.3 settings for both ends. Certificates are the only trust mechanism, and they are checked explicitly.
enum RemoteTLS {
    static let exporterLabel = "EXPORTER-MacFleet-remote-v1"
    static let exporterLength = 32

    static func serverOptions(identity: SecIdentity) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity) else { throw RemoteIdentityError.certificateUnreadable }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        return options
    }

    /// With a pin, only the pinned certificate is accepted. Without one, this is a probe for trust-on-first-use: any
    /// certificate is accepted, its fingerprint is recorded, and the caller must confirm it before pairing.
    static func clientOptions(
        pinned: HostFingerprint?,
        observation: FingerprintObservation = FingerprintObservation()
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let presented = RemoteTrustPolicy.leafFingerprint(secTrust)
            if let pinned {
                let rejection = RemoteTrustPolicy.rejection(secTrust, pinned: pinned)
                observation.record(presented, rejection: rejection)
                complete(rejection == nil)
            } else {
                observation.record(presented)
                complete(presented != nil)
            }
        }, DispatchQueue(label: "macfleet.remote.trust"))
        return options
    }

    /// Secret derived from the TLS session that both ends compute and nobody else can. Nil when the connection is not
    /// yet secured.
    static func channelBinding(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let secret = sec_protocol_metadata_create_secret(
                  metadata.securityProtocolMetadata,
                  exporterLabel.utf8.count,
                  exporterLabel,
                  exporterLength
              )
        else {
            return nil
        }
        return Data(secret as DispatchData)
    }
}
