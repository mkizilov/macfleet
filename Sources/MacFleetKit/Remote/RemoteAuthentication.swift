import CryptoKit
import Foundation
import Security

public enum RemoteAuthenticationError: Error, Equatable, Sendable {
    case invalidClientID
    case invalidSecret
    case randomSourceFailed
}

/// A client's pre-shared secret. The host and the client each keep the secret. It never crosses the network: each side
/// proves it holds the secret with an HMAC over this session's transcript.
public struct RemoteCredential: Codable, Equatable, Sendable {
    public let clientID: String
    public let secret: Data

    public init(clientID: String, secret: Data) throws {
        guard Self.isValidClientID(clientID) else { throw RemoteAuthenticationError.invalidClientID }
        guard secret.count == RemoteProtocol.secretBytes else { throw RemoteAuthenticationError.invalidSecret }
        self.clientID = clientID
        self.secret = secret
    }

    /// A new credential with a random secret. Give the secret to the client once, through a channel you trust.
    public static func generate(clientID: String) throws -> RemoteCredential {
        try RemoteCredential(clientID: clientID, secret: RemoteNonce.random(RemoteProtocol.secretBytes))
    }

    /// One to 64 characters from letters, digits, dots, underscores, and hyphens. The ID is sent in clear text during
    /// the handshake, so it must not carry anything private.
    public static func isValidClientID(_ clientID: String) -> Bool {
        (1...64).contains(clientID.count) && clientID.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clientID: container.decode(String.self, forKey: .clientID),
            secret: container.decode(Data.self, forKey: .secret)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case clientID
        case secret
    }
}

/// Random values from the system's secure generator.
public enum RemoteNonce {
    public static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "the system random source failed")
        return Data(bytes)
    }
}

/// Which side's proof this is. The labels differ, so a proof the host sends cannot be replayed back to it as the
/// client's proof.
enum RemoteAuthRole: String, Sendable {
    case client
    case host
}

/// Everything both sides agree on for one session. A proof covers all of it, so a proof from one session, or one
/// obtained through a different host or TLS session, fails in another.
struct RemoteTranscript: Equatable, Sendable {
    let version: ProtocolVersion
    let clientID: String
    let clientNonce: Data
    let serverNonce: Data
    let hostFingerprint: HostFingerprint
    /// The TLS exporter for this connection. It binds the proof to the session it was made in.
    let channelBinding: Data

    /// Each field is written with a 4-byte length in front, so no two different transcripts share bytes.
    func bytes(for role: RemoteAuthRole) -> Data {
        let fields: [Data] = [
            Data("MacFleet remote authentication v1".utf8),
            Data(role.rawValue.utf8),
            Data(version.description.utf8),
            Data(clientID.utf8),
            clientNonce,
            serverNonce,
            Data(hostFingerprint.description.utf8),
            channelBinding,
        ]
        var bytes = Data()
        for field in fields {
            var length = UInt32(field.count).bigEndian
            bytes.append(Data(bytes: &length, count: 4))
            bytes.append(field)
        }
        return bytes
    }
}

enum RemoteAuthenticator {
    static func proof(for role: RemoteAuthRole, credential: RemoteCredential, transcript: RemoteTranscript) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: transcript.bytes(for: role),
            using: SymmetricKey(data: credential.secret)
        ))
    }

    /// Constant-time comparison, so the time taken does not reveal how much of a proof matched.
    static func isValid(
        _ proof: Data,
        for role: RemoteAuthRole,
        credential: RemoteCredential,
        transcript: RemoteTranscript
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: transcript.bytes(for: role),
            using: SymmetricKey(data: credential.secret)
        )
    }
}
