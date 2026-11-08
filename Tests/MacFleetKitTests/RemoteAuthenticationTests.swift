import Foundation
import Testing
@testable import MacFleetKit

private let defaultSecret = Data(repeating: 5, count: 32)

private func credential(_ clientID: String = "laptop-1", secret: Data = defaultSecret) throws -> RemoteCredential {
    try RemoteCredential(clientID: clientID, secret: secret)
}

private func transcript(
    version: ProtocolVersion = RemoteProtocol.current,
    clientID: String = "laptop-1",
    clientNonce: Data = Data(repeating: 1, count: 32),
    serverNonce: Data = Data(repeating: 2, count: 32),
    fingerprint: HostFingerprint = HostFingerprint(certificateDER: Data("host".utf8)),
    binding: Data = Data(repeating: 9, count: 32)
) -> RemoteTranscript {
    RemoteTranscript(
        version: version,
        clientID: clientID,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        hostFingerprint: fingerprint,
        channelBinding: binding
    )
}

@Suite("Remote authentication: proofs")
struct RemoteProofTests {
    @Test func theClientProofVerifiesForTheSameSessionAndSecret() throws {
        let key = try credential()
        let proof = RemoteAuthenticator.proof(for: .client, credential: key, transcript: transcript())
        #expect(RemoteAuthenticator.isValid(proof, for: .client, credential: key, transcript: transcript()))
    }

    @Test func aWrongSecretFailsVerification() throws {
        let proof = RemoteAuthenticator.proof(for: .client, credential: try credential(), transcript: transcript())
        let imposter = try credential(secret: Data(repeating: 6, count: 32))
        #expect(!RemoteAuthenticator.isValid(proof, for: .client, credential: imposter, transcript: transcript()))
    }

    @Test func theHostProofCannotBeReplayedAsTheClientsProof() throws {
        let key = try credential()
        let hostProof = RemoteAuthenticator.proof(for: .host, credential: key, transcript: transcript())
        #expect(!RemoteAuthenticator.isValid(hostProof, for: .client, credential: key, transcript: transcript()))
        #expect(RemoteAuthenticator.isValid(hostProof, for: .host, credential: key, transcript: transcript()))
    }

    @Test func anyChangedFieldOfTheSessionInvalidatesTheProof() throws {
        let key = try credential()
        let proof = RemoteAuthenticator.proof(for: .client, credential: key, transcript: transcript())
        let changed: [(String, RemoteTranscript)] = [
            ("version", transcript(version: ProtocolVersion(major: 1, minor: 1))),
            ("client ID", transcript(clientID: "laptop-2")),
            ("client nonce", transcript(clientNonce: Data(repeating: 3, count: 32))),
            ("server nonce", transcript(serverNonce: Data(repeating: 4, count: 32))),
            ("host fingerprint", transcript(fingerprint: HostFingerprint(certificateDER: Data("another host".utf8)))),
            ("channel binding", transcript(binding: Data(repeating: 8, count: 32))),
            ("missing channel binding", transcript(binding: Data())),
        ]
        for (field, other) in changed {
            #expect(!RemoteAuthenticator.isValid(proof, for: .client, credential: key, transcript: other), "\(field) must be covered")
        }
    }

    @Test func aProofIsStableForTheSameTranscript() throws {
        let key = try credential()
        #expect(
            RemoteAuthenticator.proof(for: .client, credential: key, transcript: transcript())
                == RemoteAuthenticator.proof(for: .client, credential: key, transcript: transcript())
        )
    }

    @Test func fieldBoundariesCannotBeShifted() throws {
        // Without length prefixes, these two client IDs and nonces would produce the same bytes.
        let first = transcript(clientID: "ab", clientNonce: Data("c".utf8))
        let second = transcript(clientID: "a", clientNonce: Data("bc".utf8))
        #expect(first.bytes(for: .client) != second.bytes(for: .client))
    }
}

@Suite("Remote authentication: credentials")
struct RemoteCredentialTests {
    @Test func safeClientIDsAreAcceptedAndOtherIDsRefused() {
        for accepted in ["laptop-1", "mac_studio.2", "A", String(repeating: "x", count: 64)] {
            #expect(RemoteCredential.isValidClientID(accepted), "\(accepted) should be accepted")
        }
        for refused in ["", "has space", "../etc", "a/b", "naïve", String(repeating: "x", count: 65), "tab\tid"] {
            #expect(!RemoteCredential.isValidClientID(refused), "\(refused) should be refused")
        }
    }

    @Test func secretsMustBeExactlyTheProtocolLength() {
        #expect(throws: RemoteAuthenticationError.invalidSecret) {
            try RemoteCredential(clientID: "laptop-1", secret: Data(repeating: 1, count: 31))
        }
        #expect(throws: RemoteAuthenticationError.invalidSecret) {
            try RemoteCredential(clientID: "laptop-1", secret: Data(repeating: 1, count: 33))
        }
    }

    @Test func invalidClientIDsAreRefusedAtConstruction() {
        #expect(throws: RemoteAuthenticationError.invalidClientID) {
            try RemoteCredential(clientID: "bad id", secret: defaultSecret)
        }
    }

    @Test func generatedCredentialsAreFreshAndHaveAFullSecret() throws {
        let first = try RemoteCredential.generate(clientID: "laptop-1")
        let second = try RemoteCredential.generate(clientID: "laptop-1")
        #expect(first.secret.count == RemoteProtocol.secretBytes)
        #expect(first.secret != second.secret)
    }

    @Test func aCredentialRoundTripsThroughJSON() throws {
        let key = try credential()
        let data = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(RemoteCredential.self, from: data) == key)
    }

    @Test func aStoredCredentialWithAnInvalidIDFailsToDecode() {
        let stored = Data(#"{"clientID":"bad id","secret":"\#(defaultSecret.base64EncodedString())"}"#.utf8)
        #expect(throws: RemoteAuthenticationError.invalidClientID) {
            try JSONDecoder().decode(RemoteCredential.self, from: stored)
        }
    }

    @Test func noncesAreRandomAndHaveTheProtocolLength() {
        let first = RemoteNonce.random(RemoteProtocol.nonceBytes)
        let second = RemoteNonce.random(RemoteProtocol.nonceBytes)
        #expect(first.count == 32)
        #expect(first != second)
    }
}

@Suite("Host fingerprints")
struct HostFingerprintTests {
    @Test func theFingerprintIsTheSHA256OfTheCertificate() {
        // The SHA-256 of "abc", a published test vector.
        #expect(HostFingerprint(certificateDER: Data("abc".utf8)).hex
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func theFingerprintStringRoundTrips() throws {
        let fingerprint = HostFingerprint(certificateDER: Data("abc".utf8))
        #expect(HostFingerprint(string: fingerprint.description) == fingerprint)
        let data = try JSONEncoder().encode(fingerprint)
        #expect(try JSONDecoder().decode(HostFingerprint.self, from: data) == fingerprint)
    }

    @Test func malformedFingerprintStringsAreRefused() {
        let digits = String(repeating: "a", count: 64)
        #expect(HostFingerprint(string: "SHA1:\(digits)") == nil)
        #expect(HostFingerprint(string: "SHA256:abc") == nil)
        #expect(HostFingerprint(string: "SHA256:\(String(repeating: "g", count: 64))") == nil)
        #expect(HostFingerprint(string: digits) == nil)
    }

    @Test func parsingAcceptsUppercaseDigitsAndYieldsTheSameFingerprint() {
        let lower = HostFingerprint(certificateDER: Data("abc".utf8))
        let upper = HostFingerprint(string: "SHA256:" + lower.hex.uppercased())
        #expect(upper == lower)
    }
}
