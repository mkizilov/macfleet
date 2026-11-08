import Foundation
import MacFleetKit

/// The messages whose wire form protocol 1.0 fixes. `scripts/update-protocol-fixtures.sh` writes each one to
/// Fixtures/protocol-1.0, and ProtocolConformanceTests checks the codec against those files. Every value is fixed, so the
/// bytes change only when the wire format does.
func protocolFixtureCatalog() -> [(name: String, message: RemoteMessage)] {
    let oneZero = ProtocolVersion(major: 1, minor: 0)
    let pin = HostFingerprint(certificateDER: Data("fixture certificate".utf8))
    return [
        ("hello", .hello(ClientHello(
            clientID: "laptop-1",
            supportedVersions: [oneZero],
            clientNonce: Data(repeating: 0x11, count: 16)
        ))),
        ("helloAccepted", .helloAccepted(HostHello(
            host: HostIdentity(displayName: "studio", fingerprint: pin),
            serverNonce: Data(repeating: 0x22, count: 16)
        ))),
        ("authenticate", .authenticate(ClientProof(proof: Data(repeating: 0x33, count: 32)))),
        ("subscribe", .subscribe(SubscribeRequest(intervalSeconds: 5))),
        ("heartbeat", .heartbeat(Heartbeat(sequence: 7, sentAt: Date(timeIntervalSince1970: 1_700_000_000.5)))),
        ("error", .error(RemoteProtocolError(
            code: .unsupportedVersion,
            message: "no common version",
            retryable: false,
            supportedVersions: [oneZero]
        ))),
    ]
}
