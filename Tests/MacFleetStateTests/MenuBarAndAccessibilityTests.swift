import Foundation
import MacFleetKit
import MacFleetState
import Testing

@MainActor
private func menuBarSampledModel() async -> FleetStatusModel {
    let model = FleetStatusModel(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore())
    await model.refresh()
    return model
}

@MainActor
@Suite("Menu bar: the chosen metrics")
struct MenuBarChoiceTests {
    @Test func theLabelIsNilUntilTheFirstSample() {
        let model = FleetStatusModel(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore())
        #expect(model.menuBarLabel == nil)
    }

    @Test func theDefaultLabelShowsCPUMemoryAndNetworkInOrder() async {
        let model = await menuBarSampledModel()
        #expect(model.menuBarLabel?.items.map(\.metric) == [.cpu, .memory, .network])
        #expect(model.menuBarLabel?.visibleText.hasPrefix("CPU ") == true)
        #expect(model.menuBarLabel?.visibleText.contains(" · ") == true)
    }

    @Test func choosingMetricsChangesTheLabelInTheChosenOrder() async {
        let model = await menuBarSampledModel()
        model.setMenuBarMetrics([.disk, .memory])
        #expect(model.menuBarLabel?.items.map(\.metric) == [.disk, .memory])
        #expect(model.menuBarLabel?.visibleText.hasPrefix("Disk ") == true)
    }

    @Test func anEmptyChoiceShowsNoValuesAndSaysSo() async {
        let model = await menuBarSampledModel()
        model.setMenuBarMetrics([])
        #expect(model.menuBarLabel?.items.isEmpty == true)
        #expect(model.menuBarLabel?.visibleText == "")
        #expect(model.menuBarLabel?.accessibilityLabel == "MacFleet.")
    }

    @Test func theSpokenLabelNamesEachChosenMetricInFullWords() async {
        let model = await menuBarSampledModel()
        model.setMenuBarMetrics(MenuBarMetric.allCases)
        let spoken = model.menuBarLabel?.accessibilityLabel ?? ""
        #expect(spoken.contains("CPU "))
        #expect(spoken.contains("Memory "))
        #expect(spoken.contains("Download "))
        #expect(spoken.contains("Startup disk "))
    }
}

@Suite("Accessibility: charts and readings")
struct AccessibilityReadingTests {
    @Test func everyHistoryChartHasATitleAndASpokenSummary() {
        let series = MockHistorySource.makeSeries(range: .day, now: Date(timeIntervalSince1970: 1_767_225_600))
        let presentation = HistoryPresentation(series: series)
        #expect(presentation.charts.isEmpty == false)
        for chart in presentation.charts {
            #expect(chart.title.isEmpty == false)
            #expect(chart.spokenSummary.isEmpty == false, "\(chart.title)")
        }
    }

    @Test func everyReadingOnTheDashboardHasAPlainSpokenValue() {
        let overview = FleetOverviewPresentation(
            local: fleetSnapshot(cpu: 0.25),
            records: [],
            statuses: [:],
            pairing: .idle,
            draft: PairingDraft(),
            notice: nil,
            canAddMore: true
        )
        let tiles = overview.cards[0].metrics
        #expect(tiles.count == 5)
        for tile in tiles {
            #expect(tile.spokenValue.isEmpty == false, "\(tile.title)")
        }
    }

    @Test func anUnavailableReadingIsSpokenAsUnavailableAndShownAsADash() {
        let snapshot = RemoteSnapshot(
            capturedAt: fleetEpoch,
            cpuTotal: .unavailable(.notSampled),
            memory: .unavailable(.permissionDenied(resource: "memory statistics")),
            memoryPressure: .available(.critical),
            storage: .available([]),
            network: .unavailable(.counterReset),
            thermal: .available(.serious),
            loadAverage: .available(LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0))
        )
        let overview = FleetOverviewPresentation(
            local: snapshot,
            records: [],
            statuses: [:],
            pairing: .idle,
            draft: PairingDraft(),
            notice: nil,
            canAddMore: true
        )
        let cpu = overview.cards[0].metrics[0]
        #expect(cpu.value == "–")
        #expect(cpu.spokenValue.hasPrefix("CPU unavailable"))
    }
}
