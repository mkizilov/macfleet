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
        try withScratchDirectory { directory in
            try openssl([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", directory.key, "-out", directory.certificate, "-days", "30",
                "-subj", "/CN=macfleet-test-host",
                "-addext", "extendedKeyUsage=serverAuth",
                "-addext", "keyUsage=digitalSignature",
                "-addext", "basicConstraints=CA:FALSE",
            ])
            return try package(directory)
        }
    }

    /// A certificate whose validity ended in 2020, as an identity left unrenewed would be. Its checks must fail.
    static func makeExpiredIdentity() throws -> Identity {
        try withScratchDirectory { directory in
            try Data().write(to: URL(fileURLWithPath: directory.path("index.txt")))
            try Data("01\n".utf8).write(to: URL(fileURLWithPath: directory.path("serial.txt")))
            try Data(caConfiguration(directory).utf8).write(to: URL(fileURLWithPath: directory.path("ca.cnf")))
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", directory.key,
                         "-out", directory.path("request.pem"), "-config", directory.path("ca.cnf")])
            try openssl([
                "ca", "-selfsign", "-batch", "-config", directory.path("ca.cnf"),
                "-keyfile", directory.key, "-in", directory.path("request.pem"), "-out", directory.certificate,
                "-startdate", "20200101000000Z", "-enddate", "20200102000000Z",
                "-extensions", "ext", "-notext",
            ])
            return try package(directory)
        }
    }

    private struct Scratch {
        let root: URL

        var key: String { path("key.pem") }
        var certificate: String { path("cert.pem") }

        func path(_ name: String) -> String {
            root.appendingPathComponent(name).path
        }
    }

    private static func withScratchDirectory<T>(_ body: (Scratch) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".agent-local/remote-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Best-effort removal of a test-only directory. The keys in it were never used outside the test.
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(Scratch(root: root))
    }

    /// Packages the key and certificate as a PKCS#12 bundle with a random passphrase, and reads the DER certificate.
    private static func package(_ directory: Scratch) throws -> Identity {
        let bundle = directory.path("identity.p12")
        let der = directory.path("cert.der")
        let passphrase = RemoteNonce.random(12).map { String(format: "%02x", $0) }.joined()
        try openssl([
            "pkcs12", "-export", "-inkey", directory.key, "-in", directory.certificate, "-out", bundle,
            "-passout", "pass:\(passphrase)", "-name", "host",
        ])
        try openssl(["x509", "-in", directory.certificate, "-outform", "DER", "-out", der])
        return Identity(
            pkcs12: try Data(contentsOf: URL(fileURLWithPath: bundle)),
            passphrase: passphrase,
            certificateDER: try Data(contentsOf: URL(fileURLWithPath: der))
        )
    }

    private static func caConfiguration(_ directory: Scratch) -> String {
        """
        [ ca ]
        default_ca = CA_default
        [ CA_default ]
        database = \(directory.path("index.txt"))
        serial = \(directory.path("serial.txt"))
        new_certs_dir = \(directory.root.path)
        default_md = sha256
        policy = policy_any
        unique_subject = no
        [ policy_any ]
        commonName = supplied
        [ req ]
        distinguished_name = dn
        prompt = no
        [ dn ]
        CN = macfleet-expired-host
        [ ext ]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature
        extendedKeyUsage = serverAuth

        """
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
