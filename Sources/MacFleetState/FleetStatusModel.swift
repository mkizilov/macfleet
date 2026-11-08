import Foundation
import MacFleetKit
import Observation

/// Presents engine updates to the UI. It does no collection itself: the engine owns cadence, sleep handling, and
/// overlap rules, and the model applies each update at most once. History is read from a `HistorySource`, which does
/// its work off the main actor. Only the finished presentation is built here.
@MainActor
@Observable
public final class FleetStatusModel {
    /// How often the history section reloads while it is open.
    static let historyRefreshInterval: TimeInterval = 30
    private static let unavailableMessage = "History is not available in this session."

    public private(set) var snapshot: SystemSnapshot?
    public private(set) var dashboard: DashboardPresentation?
    public private(set) var history: MetricHistory
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public private(set) var selection = MonitoringSelection.default
    /// Expanded or collapsed popover. Held here, not in a view, so views stay free of property wrappers.
    public var isShowingDetails = false
    public private(set) var historyRange = HistoryRange.hour
    public private(set) var historyCard: HistoryCardPresentation

    private let engine: SamplingEngine
    private let historySource: (any HistorySource)?
    private let startupNotice: String?
    private var lastAppliedSequence: UInt64 = 0
    private var interactiveSampling: Task<Void, Never>?
    private var isPopoverVisible = false
    private var historySequence = 0
    private var lastHistoryAttempt: Date?

    public init(
        engine: SamplingEngine,
        historySource: (any HistorySource)? = nil,
        historyCapacity: Int = 120,
        startupNotice: String? = nil
    ) {
        self.engine = engine
        self.historySource = historySource
        self.startupNotice = startupNotice
        history = MetricHistory(capacity: historyCapacity)
        historyCard = HistoryCardPresentation(
            range: .hour,
            content: historySource == nil ? .unavailable(Self.unavailableMessage) : .loading,
            notice: startupNotice
        )
    }

    public convenience init(provider: any SystemMetricsProviding, store: any SnapshotStoring, historyCapacity: Int = 120) {
        self.init(engine: SamplingEngine(provider: provider, store: store), historyCapacity: historyCapacity)
    }

    /// Subscribes at `interval` and applies every update until the calling task is cancelled.
    /// The subscription is removed on cancellation, so the engine stops sampling when nobody is subscribed.
    public func runSampling(every interval: SamplingInterval) async {
        let subscription = await engine.subscribe(interval: interval)
        await consume(subscription)
    }

    /// Call when the popover appears. Adds an interactive subscription. The engine samples at the faster of the
    /// two rates while it exists, and falls back to the background rate when it is removed.
    public func popoverDidAppear() async {
        guard !isPopoverVisible else { return }
        isPopoverVisible = true
        let subscription = await engine.subscribe(interval: .interactive)
        guard isPopoverVisible else {
            await engine.unsubscribe(subscription.id)
            return
        }
        interactiveSampling = Task { await self.consume(subscription) }
        if isShowingDetails {
            await loadHistory()
        }
    }

    /// Call when the popover disappears. Returns once the interactive subscription is gone.
    public func popoverDidDisappear() async {
        isPopoverVisible = false
        let task = interactiveSampling
        interactiveSampling = nil
        task?.cancel()
        await task?.value
    }

    /// Samples now. Joins a collection that is already in progress rather than starting another.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        apply(await engine.collectNow())
    }

    /// Stops sampling for good. Call on app termination.
    public func shutdown() async {
        isPopoverVisible = false
        interactiveSampling?.cancel()
        interactiveSampling = nil
        await engine.shutdown()
    }

    /// The machine is about to sleep: stop scheduling.
    public func systemWillSleep() async {
        await engine.suspend()
    }

    /// The machine woke: rate baselines are dropped and sampling resumes at once.
    public func systemDidWake() async {
        await engine.resume()
    }

    public func setVolumeMonitored(_ mountPoint: String, _ monitored: Bool) async {
        selection.setVolume(at: mountPoint, monitored: monitored)
        await engine.setSelection(selection)
        rebuildDashboard()
        await refresh()
    }

    public func setInterfaceMonitored(_ name: String, _ monitored: Bool) async {
        selection.setInterface(named: name, monitored: monitored)
        await engine.setSelection(selection)
        rebuildDashboard()
        await refresh()
    }

    /// Shows or hides the history section. Showing it loads the selected range.
    public func setShowingDetails(_ showing: Bool) async {
        isShowingDetails = showing
        if showing {
            await loadHistory()
        }
    }

    public func selectHistoryRange(_ range: HistoryRange) async {
        historyRange = range
        await loadHistory()
    }

    /// Reads the selected range from the history source. A newer request supersedes an older one still in flight,
    /// so a slow answer can never overwrite the range the user chose last.
    public func loadHistory(now: Date = Date()) async {
        let range = historyRange
        lastHistoryAttempt = Date()
        historySequence += 1
        let request = historySequence
        guard let historySource else {
            historyCard = HistoryCardPresentation(
                range: range,
                content: .unavailable(Self.unavailableMessage),
                notice: startupNotice
            )
            return
        }
        historyCard = HistoryCardPresentation(range: range, content: .loading, notice: historyCard.notice)
        do {
            let series = try await historySource.series(range: range, now: now)
            let notice = await historySource.notice() ?? startupNotice
            guard request == historySequence else { return }
            historyCard = HistoryCardPresentation(
                range: range,
                content: .loaded(HistoryPresentation(series: series)),
                notice: notice
            )
        } catch {
            guard request == historySequence else { return }
            historyCard = HistoryCardPresentation(
                range: range,
                content: .unavailable(error.localizedDescription),
                notice: startupNotice
            )
        }
    }

    /// Effective sampling interval now: the fastest subscriber's, or nil when nothing is subscribed.
    public func samplingInterval() async -> SamplingInterval? {
        await engine.effectiveInterval
    }

    /// True while the engine's loop is scheduled.
    public func isSampling() async -> Bool {
        await engine.isLoopRunning
    }

    /// Applies updates until the subscription ends. Cancelling the calling task removes the subscription.
    private func consume(_ subscription: SamplingEngine.Subscription) async {
        let engine = engine
        await withTaskCancellationHandler {
            for await update in subscription.updates {
                apply(update)
            }
        } onCancel: {
            Task { await engine.unsubscribe(subscription.id) }
        }
        await engine.unsubscribe(subscription.id)
    }

    private func apply(_ update: SamplingUpdate) {
        guard update.sequence > lastAppliedSequence else { return }
        lastAppliedSequence = update.sequence
        switch update {
        case let .sample(_, snapshot):
            self.snapshot = snapshot
            history.record(snapshot)
            errorMessage = nil
            rebuildDashboard()
            refreshHistoryIfDue()
        case let .failed(_, message):
            errorMessage = message
        }
    }

    /// The history section reloads at most every `historyRefreshInterval` while it is open, and never while closed.
    private func refreshHistoryIfDue() {
        guard isShowingDetails, historySource != nil else { return }
        if let lastHistoryAttempt, Date().timeIntervalSince(lastHistoryAttempt) < Self.historyRefreshInterval {
            return
        }
        Task { await loadHistory() }
    }

    private func rebuildDashboard() {
        guard let snapshot else { return }
        dashboard = DashboardPresentation(snapshot: snapshot, history: history, selection: selection)
    }
}
