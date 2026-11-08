import Foundation

enum SamplingError: LocalizedError {
    case collectionTimedOut

    var errorDescription: String? {
        "Sampling did not finish in time."
    }
}

/// One sampling outcome, delivered to subscribers in sequence order.
public enum SamplingUpdate: Equatable, Sendable {
    case sample(sequence: UInt64, snapshot: SystemSnapshot)
    case failed(sequence: UInt64, message: String)

    public var sequence: UInt64 {
        switch self {
        case let .sample(sequence, _), let .failed(sequence, _):
            sequence
        }
    }

    public var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

/// Owns collection cadence for every consumer.
///
/// - One collection runs at a time. A request made during a collection waits for it and shares its result.
/// - The loop runs only while at least one subscriber exists, at the fastest interval any subscriber asked for.
///   It is cancelled when the last subscriber leaves, so nothing polls while nobody is watching.
/// - Failed collections back off by doubling the wait, up to a cap, and recover on the next success.
/// - Sleep is detected two ways: an explicit `suspend()`/`resume()` from the app's power notifications, and a
///   wall-clock jump that awake monotonic time does not share. Either resets rate baselines before the next
///   sample, so no rate spans a sleep.
/// - Subscribers receive every update through a stream that keeps only the newest value, so a slow consumer
///   never builds a backlog.
public actor SamplingEngine {
    public typealias Scheduler = @Sendable (Duration) async throws -> Void
    public typealias Identity = @Sendable () -> (wallClock: Date, monotonicSeconds: TimeInterval)

    public struct Subscription: Sendable {
        public let id: UUID
        public let updates: AsyncStream<SamplingUpdate>
    }

    private struct Subscriber {
        var interval: SamplingInterval
        let continuation: AsyncStream<SamplingUpdate>.Continuation
    }

    private struct Collection {
        let sequence: UInt64
        let task: Task<SamplingUpdate, Never>
    }

    /// A wall-clock gap this much longer than the awake gap means the machine was asleep in between.
    static let sleepThreshold: TimeInterval = 2

    private let provider: any SystemMetricsProviding
    private let store: any SnapshotStoring
    private let scheduler: Scheduler
    private let collectionDeadline: Duration
    private let identity: Identity
    private let maximumBackoff: TimeInterval
    private var selection = MonitoringSelection.default
    private var subscribers: [UUID: Subscriber] = [:]
    private var latest: SamplingUpdate?
    private var inFlight: Collection?
    private var loop: Task<Void, Never>?
    private var loopGeneration = 0
    private var sequence: UInt64 = 0
    private var isSuspended = false
    private var isShutdown = false
    private var baselineResetPending = false
    private var lastIdentity: (wallClock: Date, monotonicSeconds: TimeInterval)?

    /// Collections that ran to completion. Requests that joined a running collection are not counted.
    public private(set) var completedCollections = 0

    public init(
        provider: any SystemMetricsProviding,
        store: any SnapshotStoring,
        maximumBackoff: Duration = .seconds(60),
        collectionDeadline: Duration = .seconds(10),
        scheduler: @escaping Scheduler = { try await Task.sleep(for: $0, clock: .suspending) },
        identity: @escaping Identity = { (Date(), MonotonicTime.awakeSeconds()) }
    ) {
        self.provider = provider
        self.store = store
        self.maximumBackoff = maximumBackoff.totalSeconds
        self.collectionDeadline = collectionDeadline
        self.scheduler = scheduler
        self.identity = identity
    }

    // MARK: Subscriptions

    /// Registers a subscriber. A subscriber that arrives after a sample receives that sample immediately.
    ///
    /// The subscription lasts as long as its `updates` stream: releasing the stream, or cancelling the task
    /// that consumes it, unsubscribes. Keep the `Subscription` alive for as long as you want updates.
    public func subscribe(interval: SamplingInterval) -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SamplingUpdate.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard !isShutdown else {
            continuation.finish()
            return Subscription(id: id, updates: stream)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        if let latest {
            continuation.yield(latest)
        }
        subscribers[id] = Subscriber(interval: interval, continuation: continuation)
        reschedule()
        return Subscription(id: id, updates: stream)
    }

    public func unsubscribe(_ id: UUID) async {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.finish()
        if subscribers.isEmpty {
            await stopLoop()
        } else {
            reschedule()
        }
    }

    /// Changes one subscriber's interval. The loop restarts at the new effective cadence.
    public func setInterval(_ interval: SamplingInterval, for id: UUID) {
        guard subscribers[id] != nil else { return }
        subscribers[id]?.interval = interval
        reschedule()
    }

    public func setSelection(_ selection: MonitoringSelection) {
        self.selection = selection
    }

    public var subscriberCount: Int {
        subscribers.count
    }

    /// Effective loop interval: the fastest subscriber's, or nil when nobody is subscribed.
    public var effectiveInterval: SamplingInterval? {
        subscribers.values.map(\.interval).min()
    }

    public var isLoopRunning: Bool {
        loop != nil
    }

    // MARK: Collection

    /// Collects now. Joins a collection that is already running rather than starting a second one.
    public func collectNow() async -> SamplingUpdate {
        if isShutdown {
            return .failed(sequence: sequence, message: "Sampling has stopped.")
        }
        if let collection = inFlight {
            return await collection.task.value
        }
        sequence += 1
        let number = sequence
        let task = Task { await self.performCollection(number) }
        inFlight = Collection(sequence: number, task: task)
        let update = await task.value
        if inFlight?.sequence == number {
            inFlight = nil
        }
        return update
    }

    private func performCollection(_ number: UInt64) async -> SamplingUpdate {
        let now = identity()
        if let previous = lastIdentity,
           Self.slept(
               wallDelta: now.wallClock.timeIntervalSince(previous.wallClock),
               monotonicDelta: now.monotonicSeconds - previous.monotonicSeconds
           ) {
            baselineResetPending = true
        }
        lastIdentity = now

        if baselineResetPending {
            baselineResetPending = false
            await provider.resetBaselines()
        }

        let update = await collectWithDeadline(number)
        completedCollections += 1
        latest = update
        for subscriber in subscribers.values {
            subscriber.continuation.yield(update)
        }
        return update
    }

    /// Runs one provider call under a deadline. A provider that ignores cancellation still cannot hold the loop:
    /// the race returns a failure as soon as the deadline passes, and the late result is discarded.
    private func collectWithDeadline(_ number: UInt64) async -> SamplingUpdate {
        let provider = provider
        let selection = selection
        let store = store
        let outcome = await raceAgainstDeadline(collectionDeadline) { () -> SamplingUpdate in
            do {
                let snapshot = try await provider.snapshot(selection: selection)
                await store.save(snapshot)
                return .sample(sequence: number, snapshot: snapshot)
            } catch {
                return .failed(sequence: number, message: error.localizedDescription)
            }
        }
        switch outcome {
        case let .finished(update):
            return update
        case .timedOut:
            return .failed(sequence: number, message: SamplingError.collectionTimedOut.localizedDescription)
        }
    }

    /// Wall time advanced more than awake monotonic time did, so the machine slept in between.
    static func slept(wallDelta: TimeInterval, monotonicDelta: TimeInterval) -> Bool {
        wallDelta - monotonicDelta > sleepThreshold
    }

    // MARK: Loop

    private func reschedule() {
        loop?.cancel()
        loop = nil
        startLoop()
    }

    private func startLoop() {
        guard !isSuspended, !isShutdown, !subscribers.isEmpty, loop == nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        loop = Task { await self.runLoop(generation: generation) }
    }

    private func stopLoop() async {
        let running = loop
        loop = nil
        running?.cancel()
        await running?.value
        if let collection = inFlight {
            _ = await collection.task.value
        }
    }

    private func runLoop(generation: Int) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            let update = await collectNow()
            consecutiveFailures = update.isFailure ? consecutiveFailures + 1 : 0
            guard let interval = effectiveInterval else { break }
            let wait = Self.wait(for: interval, failures: consecutiveFailures, cap: maximumBackoff)
            do {
                try await scheduler(wait)
            } catch {
                break
            }
        }
        if generation == loopGeneration {
            loop = nil
        }
    }

    static func wait(for interval: SamplingInterval, failures: Int, cap: TimeInterval) -> Duration {
        guard failures > 0 else { return interval.duration }
        let factor = Double(1 << min(failures, 10))
        return .fromSeconds(min(interval.seconds * factor, cap))
    }

    // MARK: Lifecycle

    /// The machine is going to sleep. Stop the loop so nothing is scheduled while asleep.
    public func suspend() async {
        isSuspended = true
        await stopLoop()
        await store.flush()
    }

    /// The machine woke. Drop rate baselines (counters may have reset across sleep) and sample again now.
    public func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        baselineResetPending = true
        if let collection = inFlight {
            _ = await collection.task.value
        }
        startLoop()
    }

    /// Stop sampling, finish every subscriber, and wait for any collection in progress.
    public func shutdown() async {
        isShutdown = true
        let active = subscribers.values
        subscribers.removeAll()
        for subscriber in active {
            subscriber.continuation.finish()
        }
        await stopLoop()
        await store.flush()
    }
}
