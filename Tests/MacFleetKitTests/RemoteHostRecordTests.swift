import Foundation
import Testing
@testable import MacFleetKit

private let stamp = Date(timeIntervalSince1970: 1_700_000_000.5)

private func record(label: String = "Studio", fingerprintSeed: String = "host-a") -> RemoteHostRecord {
    RemoteHostRecord(
        id: UUID(uuidString: "5F0C2E4A-0000-4000-8000-000000000001")!,
        label: label,
        host: "studio.tail1234.ts.net",
        port: 21440,
        clientID: "laptop-1",
        pinnedFingerprint: HostFingerprint(certificateDER: Data(fingerprintSeed.utf8)),
        addedAt: stamp
    )
}

private func withSuite(_ body: (String) throws -> Void) rethrows {
    let suite = "MacFleetTests.remote.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    try body(suite)
}

@Suite("Remote host records")
struct RemoteHostRecordTests {
    @Test func aRecordRoundTripsWithItsPinAndTimestamp() throws {
        let original = record()
        let data = try JSONEncoder().encode([original])
        #expect(try JSONDecoder().decode([RemoteHostRecord].self, from: data) == [original])
    }

    @Test func aRecordHoldsNoSecret() throws {
        let text = String(decoding: try JSONEncoder().encode(record()), as: UTF8.self)
        #expect(!text.contains("secret"))
        #expect(text.contains("pinnedFingerprint"))
    }

    @Test func repinningChangesOnlyTheFingerprint() {
        let original = record()
        let newFingerprint = HostFingerprint(certificateDER: Data("host-b".utf8))
        let repinned = original.pinned(to: newFingerprint)
        #expect(repinned.pinnedFingerprint == newFingerprint)
        #expect(repinned.id == original.id)
        #expect(repinned.label == original.label)
        #expect(repinned.endpoint == original.endpoint)
        #expect(repinned.addedAt == original.addedAt)
    }

    @Test func aDefaultsStoreKeepsTheListAcrossInstances() throws {
        try withSuite { suite in
            let records = [record(label: "Studio"), record(label: "Mini", fingerprintSeed: "host-c")]
            try UserDefaultsRemoteHostStore(suiteName: suite).save(records)
            #expect(try UserDefaultsRemoteHostStore(suiteName: suite).load() == records)
        }
    }

    @Test func aDefaultsStoreWithNothingSavedLoadsAnEmptyList() throws {
        try withSuite { suite in
            let loaded = try UserDefaultsRemoteHostStore(suiteName: suite).load()
            #expect(loaded.isEmpty)
        }
    }

    @Test func damagedSavedDataIsMovedAsideNotDeleted() throws {
        try withSuite { suite in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(Data("not a list".utf8), forKey: UserDefaultsRemoteHostStore.key)
            let store = UserDefaultsRemoteHostStore(suiteName: suite)

            do {
                _ = try store.load()
                Issue.record("damaged data must not load")
            } catch RemoteHostStoreError.damaged(let aside) {
                #expect(aside.hasPrefix(UserDefaultsRemoteHostStore.key + ".damaged."))
                #expect(defaults.data(forKey: aside) == Data("not a list".utf8))
                #expect(defaults.data(forKey: UserDefaultsRemoteHostStore.key) == nil)
            }
            // After the move the store is empty and can be saved again.
            #expect(try store.load().isEmpty)
        }
    }

    @Test func theMemoryStoreReportsItsInjectedFailures() throws {
        let failing = MemoryRemoteHostStore(loadFailure: .unreadable("locked"))
        #expect(throws: RemoteHostStoreError.unreadable("locked")) {
            try failing.load()
        }
        let refusing = MemoryRemoteHostStore(saveFailure: CocoaError(.fileWriteNoPermission))
        #expect(throws: CocoaError.self) {
            try refusing.save([record()])
        }
        let working = MemoryRemoteHostStore()
        try working.save([record()])
        #expect(try working.load() == [record()])
    }
}
