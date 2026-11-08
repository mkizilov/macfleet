import Darwin
import Foundation
import os
import Security

public enum AgentSecretError: Error, Equatable, Sendable, CustomStringConvertible {
    case notOwnedByCurrentUser(path: String)
    case accessibleToOthers(path: String, mode: Int)
    case unreadable(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case corruptStore(path: String)
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case let .notOwnedByCurrentUser(path):
            "\(path) is not owned by the current user, so it will not be read"
        case let .accessibleToOthers(path, mode):
            "\(path) is accessible to other accounts (mode \(String(mode, radix: 8))); make it owner-only with chmod 600"
        case let .unreadable(path, reason):
            "\(path) could not be read: \(reason)"
        case let .writeFailed(path, reason):
            "\(path) could not be written: \(reason)"
        case let .corruptStore(path):
            "the secret store at \(path) is damaged"
        case let .keychain(status):
            "the keychain refused the request (status \(status))"
        }
    }
}

/// Keeps the agent's secrets: client secrets and the identity passphrase. A value is never written to a log.
public protocol AgentSecretStore: Sendable {
    func secret(for account: String) throws -> Data?
    func setSecret(_ value: Data, for account: String) throws
    func removeSecret(for account: String) throws
}

public enum AgentSecretAccount {
    public static let identityPassphrase = "identity.passphrase"

    public static func client(_ clientID: String) -> String {
        "client.\(clientID)"
    }
}

/// Files that hold secrets or the identity. A file is read only when the current user owns it and no other account
/// has any access. This is the rule ssh applies to private keys.
public enum ProtectedFile {
    /// A symbolic link is refused, so the owner check always applies to the file the path names.
    public static func read(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentSecretError.unreadable(path: path, reason: String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw AgentSecretError.unreadable(path: path, reason: String(cString: strerror(errno)))
        }
        try check(info, path: path)
        return try handle.readToEnd() ?? Data()
    }

    public static func requireOwnerOnly(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw AgentSecretError.unreadable(path: path, reason: String(cString: strerror(errno)))
        }
        try check(info, path: path)
    }

    /// Writes the file with owner-only permissions. The data goes to a new file that is then renamed over the old one,
    /// so a reader never sees a partly written file.
    public static func write(_ data: Data, to path: String, permissions: mode_t = 0o600) throws {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw AgentSecretError.writeFailed(path: path, reason: error.localizedDescription)
        }
        let temporary = "\(path).\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, permissions)
        guard descriptor >= 0 else {
            throw AgentSecretError.writeFailed(path: path, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            unlink(temporary)
            throw AgentSecretError.writeFailed(path: path, reason: error.localizedDescription)
        }
        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw AgentSecretError.writeFailed(path: path, reason: reason)
        }
    }

    private static func check(_ info: stat, path: String) throws {
        guard info.st_uid == geteuid() else {
            throw AgentSecretError.notOwnedByCurrentUser(path: path)
        }
        let mode = Int(info.st_mode) & 0o777
        guard mode & 0o077 == 0 else {
            throw AgentSecretError.accessibleToOthers(path: path, mode: mode)
        }
    }
}

/// Secrets in an owner-only JSON file. The file maps each account to its secret, base64 encoded.
public struct ProtectedFileSecretStore: AgentSecretStore {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func secret(for account: String) throws -> Data? {
        guard let encoded = try load()[account] else { return nil }
        guard let value = Data(base64Encoded: encoded) else {
            throw AgentSecretError.corruptStore(path: path)
        }
        return value
    }

    public func setSecret(_ value: Data, for account: String) throws {
        var entries = try load()
        entries[account] = value.base64EncodedString()
        try save(entries)
    }

    public func removeSecret(for account: String) throws {
        var entries = try load()
        entries[account] = nil
        try save(entries)
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try ProtectedFile.read(path)
        guard let entries = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw AgentSecretError.corruptStore(path: path)
        }
        return entries
    }

    private func save(_ entries: [String: String]) throws {
        try ProtectedFile.write(try JSONEncoder().encode(entries), to: path)
    }
}

/// Secrets in the login keychain, under the service `com.macfleet.headless`. The keychain is only used when the
/// configuration asks for it. It is not exercised by the automated tests, because they must not change the keychain.
public struct KeychainSecretStore: AgentSecretStore {
    public static let service = "com.macfleet.headless"

    public init() {}

    public func secret(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw AgentSecretError.keychain(status)
        }
    }

    public func setSecret(_ value: Data, for account: String) throws {
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecItemNotFound {
            var item = baseQuery(account)
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw AgentSecretError.keychain(added) }
            return
        }
        guard update == errSecSuccess else { throw AgentSecretError.keychain(update) }
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentSecretError.keychain(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Secrets in memory, for tests and previews.
public final class MemoryAgentSecretStore: AgentSecretStore, Sendable {
    private let values: OSAllocatedUnfairLock<[String: Data]>

    public init(_ values: [String: Data] = [:]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    public func secret(for account: String) throws -> Data? {
        values.withLock { $0[account] }
    }

    public func setSecret(_ value: Data, for account: String) throws {
        values.withLock { $0[account] = value }
    }

    public func removeSecret(for account: String) throws {
        values.withLock { $0[account] = nil }
    }
}
