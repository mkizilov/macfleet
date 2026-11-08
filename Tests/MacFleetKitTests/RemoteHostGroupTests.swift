import Foundation
import Testing
@testable import MacFleetKit

@Suite("Remote host groups")
struct RemoteHostGroupTests {
    private func groupedRecord(_ group: String?) -> RemoteHostRecord {
        RemoteHostRecord(
            id: UUID(uuidString: "5F0C2E4A-0000-4000-8000-0000000000A1")!,
            label: "Studio",
            host: "studio.tail1234.ts.net",
            port: 21440,
            clientID: "laptop-1",
            pinnedFingerprint: HostFingerprint(certificateDER: Data("group host".utf8)),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            group: group
        )
    }

    /// A record saved before groups existed has no group key. It must still load, as ungrouped.
    @Test func aRecordSavedBeforeGroupsExistedDecodesWithoutAGroup() throws {
        let encoded = try JSONEncoder().encode([groupedRecord("Lab")])
        var entries = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        entries[0].removeValue(forKey: "group")
        let legacy = try JSONSerialization.data(withJSONObject: entries)
        let decoded = try JSONDecoder().decode([RemoteHostRecord].self, from: legacy)
        #expect(decoded.first?.group == nil)
        #expect(decoded.first?.label == "Studio")
    }

    @Test func aGroupRoundTripsThroughJSON() throws {
        let record = groupedRecord("Lab")
        let decoded = try JSONDecoder().decode([RemoteHostRecord].self, from: JSONEncoder().encode([record]))
        #expect(decoded == [record])
    }

    @Test func groupNamesAreTrimmedAndBlankNamesMeanNoGroup() {
        #expect(RemoteHostRecord.normalizedGroup("  Lab  ") == "Lab")
        #expect(RemoteHostRecord.normalizedGroup("") == nil)
        #expect(RemoteHostRecord.normalizedGroup("   ") == nil)
        #expect(RemoteHostRecord.normalizedGroup(nil) == nil)
    }

    @Test func regroupingChangesOnlyTheGroup() {
        let original = groupedRecord("Lab")
        let moved = original.grouped("Office")
        #expect(moved.group == "Office")
        #expect(moved.id == original.id)
        #expect(moved.label == original.label)
        #expect(moved.pinnedFingerprint == original.pinnedFingerprint)
        #expect(moved.grouped(nil).group == nil)
        #expect(original.pinned(to: original.pinnedFingerprint).group == "Lab")
    }
}
