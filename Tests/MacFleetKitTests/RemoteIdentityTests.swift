import Foundation
import Security
import Testing
@testable import MacFleetKit

@Suite("Host identity import and pinning", .enabled(if: RemoteTestSupport.memoryOnlyImportAvailable))
struct RemoteIdentityTests {
    @Test func theImportedIdentityHasTheFingerprintOfItsCertificate() throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let imported = try RemoteHostIdentityImport.importIdentity(
            pkcs12: identity.pkcs12,
            passphrase: identity.passphrase
        )
        #expect(imported.fingerprint == HostFingerprint(certificateDER: identity.certificateDER))
    }

    @Test func aWrongPassphraseIsRefused() throws {
        let identity = try RemoteTestSupport.makeIdentity()
        #expect(throws: RemoteIdentityError.self) {
            try RemoteHostIdentityImport.importIdentity(pkcs12: identity.pkcs12, passphrase: "not the passphrase")
        }
    }

    @Test func aGarbageBundleIsRefused() {
        #expect(throws: RemoteIdentityError.self) {
            try RemoteHostIdentityImport.importIdentity(pkcs12: Data("not a bundle".utf8), passphrase: "x")
        }
    }

    @Test func aPinAcceptsOnlyTheMatchingCertificate() throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates([certificate] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let evaluated = try #require(trust)

        #expect(RemoteTrustPolicy.accepts(evaluated, pinned: HostFingerprint(certificateDER: identity.certificateDER)))
        #expect(!RemoteTrustPolicy.accepts(evaluated, pinned: HostFingerprint(certificateDER: Data("other".utf8))))
    }
}
