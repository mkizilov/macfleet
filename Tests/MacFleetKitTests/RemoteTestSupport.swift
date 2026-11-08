import Foundation
@testable import MacFleetKit

enum RemoteTestSupportError: Error {
    case opensslFailed(String)
}

/// Helpers for the remote protocol tests. Test identities are made with the system's openssl, written under the
/// repository's `.agent-local` directory, and removed before the helper returns. No key outlives the test.
enum RemoteTestSupport {
    struct Identity {
        let pkcs12: Data
        let passphrase: String
        let certificateDER: Data
    }

    /// The memory-only PKCS#12 import needs macOS 15. Tests that need a real identity are skipped on older systems.
    static var memoryOnlyImportAvailable: Bool {
        if #available(macOS 15.0, *) {
            true
        } else {
            false
        }
    }

    static func makeIdentity() throws -> Identity {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent-local/remote-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Best-effort removal of a test-only directory. The keys in it were never used outside the test.
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = directory.appendingPathComponent("key.pem").path
        let certificate = directory.appendingPathComponent("cert.pem").path
        let bundle = directory.appendingPathComponent("identity.p12").path
        let der = directory.appendingPathComponent("cert.der").path
        let passphrase = RemoteNonce.random(12).map { String(format: "%02x", $0) }.joined()

        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key, "-out", certificate, "-days", "30",
            "-subj", "/CN=macfleet-test-host",
            "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "keyUsage=digitalSignature",
            "-addext", "basicConstraints=CA:FALSE",
        ])
        try openssl([
            "pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", bundle,
            "-passout", "pass:\(passphrase)", "-name", "host",
        ])
        try openssl(["x509", "-in", certificate, "-outform", "DER", "-out", der])

        return Identity(
            pkcs12: try Data(contentsOf: URL(fileURLWithPath: bundle)),
            passphrase: passphrase,
            certificateDER: try Data(contentsOf: URL(fileURLWithPath: der))
        )
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RemoteTestSupportError.opensslFailed(arguments.first ?? "")
        }
    }
}
