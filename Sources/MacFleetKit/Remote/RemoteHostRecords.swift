import Foundation
import os

/// A Mac the user registered for remote monitoring. It holds no secret: the client secret lives in a secret store under
/// the record's ID. The pinned fingerprint is the identity the user confirmed.
public struct RemoteHostRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let host: String
    public let port: UInt16
    public let clientID: String
    public let pinnedFingerprint: HostFingerprint
    public let addedAt: Date
    /// The group this Mac is shown under. Nil means ungrouped. Records saved before groups existed decode with nil.
    public let group: String?

    public init(
        id: UUID = UUID(),
        label: String,
        host: String,
        port: UInt16,
        clientID: String,
        pinnedFingerprint: HostFingerprint,
        addedAt: Date,
        group: String? = nil
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.clientID = clientID
        self.pinnedFingerprint = pinnedFingerprint
        self.addedAt = addedAt
        self.group = group
    }

    public static let maximumGroupLength = 32

    /// The group name as the user meant it: trimmed, and nil when nothing is left.
    public static func normalizedGroup(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public var endpoint: RemoteEndpoint {
        RemoteEndpoint(host: host, port: port)
    }

    public func grouped(_ name: String?) -> RemoteHostRecord {
        RemoteHostRecord(
            id: id,
            label: label,
            host: host,
            port: port,
            clientID: clientID,
            pinnedFingerprint: pinnedFingerprint,
            addedAt: addedAt,
            group: Self.normalizedGroup(name)
        )
    }

    /// The same host with a new pinned identity, used after the user confirms a changed certificate.
    public func pinned(to fingerprint: HostFingerprint) -> RemoteHostRecord {
        RemoteHostRecord(
            id: id,
            label: label,
            host: host,
            port: port,
            clientID: clientID,
            pinnedFingerprint: fingerprint,
            addedAt: addedAt,
            group: group
        )
    }
}

public enum RemoteHostStoreError: Error, Equatable, Sendable {
    /// Saved data could not be read. It was moved aside under `movedAside` and nothing was deleted.
    case damaged(movedAside: String)
    /// Saved data could not be read and could not be moved aside, so saving over it would be unsafe.
    case unreadable(String)
}

public protocol RemoteHostStoring: Sendable {
    func load() throws -> [RemoteHostRecord]
    func save(_ records: [RemoteHostRecord]) throws
}

/// Keeps the registered Macs in user defaults, as one encoded list. Damaged data is moved aside, never deleted, so a
/// pinned identity can still be inspected after a failed read.
public struct UserDefaultsRemoteHostStore: RemoteHostStoring {
    public static let key = "MacFleet.remoteHosts"

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() throws -> [RemoteHostRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            return try JSONDecoder().decode([RemoteHostRecord].self, from: data)
        } catch {
            let aside = "\(Self.key).damaged.\(Int(Date().timeIntervalSince1970))"
            defaults.set(data, forKey: aside)
            defaults.removeObject(forKey: Self.key)
            throw RemoteHostStoreError.damaged(movedAside: aside)
        }
    }

    public func save(_ records: [RemoteHostRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: Self.key)
    }
}

/// Keeps records in memory, with optional failures on load or save, for tests and previews.
public final class MemoryRemoteHostStore: RemoteHostStoring, Sendable {
    private let records: OSAllocatedUnfairLock<[RemoteHostRecord]>
    private let loadFailure: RemoteHostStoreError?
    private let saveFailure: (any Error)?

    public init(
        records: [RemoteHostRecord] = [],
        loadFailure: RemoteHostStoreError? = nil,
        saveFailure: (any Error)? = nil
    ) {
        self.records = OSAllocatedUnfairLock(initialState: records)
        self.loadFailure = loadFailure
        self.saveFailure = saveFailure
    }

    public func load() throws -> [RemoteHostRecord] {
        if let loadFailure {
            throw loadFailure
        }
        return records.withLock { $0 }
    }

    public func save(_ updated: [RemoteHostRecord]) throws {
        if let saveFailure {
            throw saveFailure
        }
        records.withLock { $0 = updated }
    }
}
