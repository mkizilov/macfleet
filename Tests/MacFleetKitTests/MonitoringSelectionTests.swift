import Foundation
import Testing
@testable import MacFleetKit

@Suite("Monitoring selection")
struct MonitoringSelectionTests {
    @Test func defaultMonitorsEverythingExceptLoopback() {
        let selection = MonitoringSelection.default
        #expect(selection.monitorsVolume(at: "/"))
        #expect(selection.monitorsInterface(named: "en0"))
        #expect(!selection.monitorsInterface(named: "lo0"))
    }

    @Test func togglingVolumesAddsAndRemovesExclusions() {
        var selection = MonitoringSelection.default
        selection.setVolume(at: "/Volumes/USB", monitored: false)
        #expect(!selection.monitorsVolume(at: "/Volumes/USB"))
        selection.setVolume(at: "/Volumes/USB", monitored: true)
        #expect(selection.monitorsVolume(at: "/Volumes/USB"))
    }

    @Test func togglingInterfacesAddsAndRemovesExclusions() {
        var selection = MonitoringSelection.default
        selection.setInterface(named: "lo0", monitored: true)
        #expect(selection.monitorsInterface(named: "lo0"))
        selection.setInterface(named: "en1", monitored: false)
        #expect(selection.excludedInterfaceNames == ["en1"])
    }

    @Test func selectionRoundTripsThroughJSON() throws {
        let selection = MonitoringSelection(excludedVolumePaths: ["/Volumes/USB"], excludedInterfaceNames: ["lo0", "awdl0"])
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(MonitoringSelection.self, from: data)
        #expect(decoded == selection)
    }
}
