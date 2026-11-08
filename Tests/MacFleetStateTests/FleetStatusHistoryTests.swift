import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// Counts requests and reports a storage notice, so tests can check how often history is read.
private actor ScriptedHistorySource: HistorySource {
    private(set) var calls = 0
    private let storageNotice: String?

    init(storageNotice: String? = nil) {
        self.storageNotice = storageNotice
    }

    func series(range: HistoryRange, now: Date) async throws -> HistorySeries {
        calls += 1
        return MockHistorySource.makeSeries(range: range, now: now)
    }

    func notice() async -> String? {
        storageNotice
    }
}

/// Answers hour requests late and other ranges at once, so a stale answer can arrive after a newer one.
private actor DelayedHistorySource: HistorySource {
    private(set) var requests: [HistoryRange] = []

    func series(range: HistoryRange, now: Date) async throws -> HistorySeries {
        requests.append(range)
        if range == .hour {
            try await Task.sleep(for: .milliseconds(150))
        }
        return MockHistorySource.makeSeries(range: range, now: now)
    }

    func notice() async -> String? {
        nil
    }
}

private func kind(_ content: HistoryCardPresentation.Content) -> String {
    switch content {
    case .loading: "loading"
    case .loaded: "loaded"
    case .unavailable: "unavailable"
    }
}

@MainActor
private func makeModel(source: (any HistorySource)?, notice: String? = nil) -> FleetStatusModel {
    FleetStatusModel(
        engine: SamplingEngine(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore()),
        historySource: source,
        startupNotice: notice
    )
}

@MainActor
@Suite("History in the model")
struct FleetStatusHistoryTests {
    @Test func loadingShowsTheSelectedRange() async {
        let model = makeModel(source: MockHistorySource())
        await model.loadHistory()
        #expect(kind(model.historyCard.content) == "loaded")
        #expect(model.historyCard.range == .hour)
        #expect(model.historyCard.notice == nil)
    }

    @Test func selectingARangeLoadsThatRange() async {
        let model = makeModel(source: MockHistorySource())
        await model.selectHistoryRange(.week)
        #expect(model.historyRange == .week)
        #expect(model.historyCard.range == .week)
        #expect(model.historyCard.content != .loading)
        if case let .loaded(presentation) = model.historyCard.content {
            #expect(presentation.caption.hasPrefix("Last week"))
        } else {
            Issue.record("the week range should be loaded")
        }
    }

    /// A slow answer for the hour range arrives after the user chose the day range. It must not replace the day
    /// range on screen.
    @Test func aStaleAnswerNeverOverwritesTheLatestChoice() async {
        let source = DelayedHistorySource()
        let model = makeModel(source: source)
        let slow = Task { await model.loadHistory() }

        var attempts = 0
        while await source.requests.isEmpty, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        #expect(attempts < 10_000)

        await model.selectHistoryRange(.day)
        await slow.value

        #expect(model.historyCard.range == .day)
        if case let .loaded(presentation) = model.historyCard.content {
            #expect(presentation.caption.hasPrefix("Last day"))
        } else {
            Issue.record("the day range should be loaded")
        }
    }

    @Test func aFailedReadIsShownWithItsReason() async {
        let failure = HistoryError.sqlite("disk I/O error")
        let model = makeModel(source: MockHistorySource(failure: failure))
        await model.loadHistory()
        guard case let .unavailable(reason) = model.historyCard.content else {
            Issue.record("a failed read should be unavailable")
            return
        }
        #expect(reason.contains("disk I/O error"))
    }

    @Test func storageNoticesReachTheCard() async {
        let model = makeModel(source: ScriptedHistorySource(storageNotice: "History is not being saved: disk full"))
        await model.loadHistory()
        #expect(model.historyCard.notice == "History is not being saved: disk full")
    }

    @Test func aStartupNoticeIsShownEvenWithoutAHistorySource() async {
        let model = makeModel(source: nil, notice: "History is kept for this session only.")
        await model.loadHistory()
        #expect(kind(model.historyCard.content) == "unavailable")
        #expect(model.historyCard.notice == "History is kept for this session only.")
    }

    @Test func showingTheSectionLoadsHistoryAndHidingItDoesNot() async {
        let source = ScriptedHistorySource()
        let model = makeModel(source: source)
        await model.setShowingDetails(true)
        #expect(await source.calls == 1)
        await model.setShowingDetails(false)
        #expect(await source.calls == 1)
    }

    /// Samples arriving while the section is open must not reread history on every update.
    @Test func openHistoryIsNotRereadOnEverySample() async {
        let source = ScriptedHistorySource()
        let model = makeModel(source: source)
        await model.setShowingDetails(true)
        await model.refresh()
        await model.refresh()
        #expect(await source.calls == 1)
    }

    @Test func closedHistoryIsNeverReadBySamples() async {
        let source = ScriptedHistorySource()
        let model = makeModel(source: source)
        await model.refresh()
        #expect(await source.calls == 0)
    }
}
