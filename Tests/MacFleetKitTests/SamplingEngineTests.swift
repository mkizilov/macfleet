import Foundation
import Testing
@testable import MacFleetKit

private func makeEngine(
    _ provider: any SystemMetricsProviding,
    _ scheduler: ManualScheduler
) -> SamplingEngine {
    SamplingEngine(provider: provider, store: InMemorySnapshotStore(), scheduler: scheduler.scheduler)
}

private func sequenceOf(_ iterator: inout AsyncStream<SamplingUpdate>.AsyncIterator) async throws -> UInt64 {
    try #require(await iterator.next()).sequence
}

@Suite("Sampling engine: subscriptions")
struct SamplingEngineSubscriptionTests {
    @Test func concurrentSubscribersReceiveTheSameCollection() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        let subscriptions = [
            await engine.subscribe(interval: .interactive),
            await engine.subscribe(interval: .interactive),
            await engine.subscribe(interval: .background),
        ]
        await scheduler.waitUntilSleeping()

        var sequences: [UInt64] = []
        for subscription in subscriptions {
            var iterator = subscription.updates.makeAsyncIterator()
            sequences.append(try await sequenceOf(&iterator))
        }
        #expect(Set(sequences).count == 1)
        await engine.shutdown()
    }

    @Test func lateSubscriberReceivesTheLatestCollectionNotAStaleOne() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        _ = await engine.collectNow()

        let subscription = await engine.subscribe(interval: .background)
        await scheduler.waitUntilSleeping()

        var iterator = subscription.updates.makeAsyncIterator()
        #expect(try await sequenceOf(&iterator) == 2)
        await engine.shutdown()
    }

    @Test func slowSubscriberHoldsOnlyTheNewestUpdate() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        let subscription = await engine.subscribe(interval: .interactive)

        await scheduler.waitUntilSleeping()
        scheduler.advance(by: 2)
        await scheduler.waitUntilSleeping()
        scheduler.advance(by: 2)
        await scheduler.waitUntilSleeping()

        var iterator = subscription.updates.makeAsyncIterator()
        #expect(try await sequenceOf(&iterator) == 3)
        await engine.shutdown()
    }

    @Test func unsubscribingStopsSamplingAndManualCollectionStillWorks() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider()
        let engine = makeEngine(provider, scheduler)
        let subscription = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()

        await engine.unsubscribe(subscription.id)
        #expect(await engine.subscriberCount == 0)
        #expect(await engine.isLoopRunning == false)
        #expect(scheduler.sleeperCount == 0)

        let calls = await provider.calls
        scheduler.advance(by: 100)
        #expect(await provider.calls == calls)

        _ = await engine.collectNow()
        #expect(await provider.calls == calls + 1)
    }

    /// A subscription ends when its stream is released. Dropping it must stop sampling, so no caller can leave
    /// an orphaned loop polling in the background.
    @Test func droppingASubscriptionEndsItsSampling() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        var subscription: SamplingEngine.Subscription? = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()
        #expect(subscription != nil)

        subscription = nil
        var released = false
        for _ in 0..<1_000 where !released {
            await Task.yield()
            released = await engine.subscriberCount == 0
        }
        #expect(released, "the engine still holds a subscriber after its stream was released")
        #expect(await engine.isLoopRunning == false)
        await engine.shutdown()
    }

    @Test func cancelledSubscriberIsRemovedAndFinishesItsStream() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        let subscription = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()

        await engine.unsubscribe(subscription.id)
        var iterator = subscription.updates.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await iterator.next() == nil)
    }

    @Test func selectionIsAppliedToEveryCollection() async throws {
        let provider = RecordingSystemProvider()
        let engine = SamplingEngine(provider: provider, store: InMemorySnapshotStore())
        await engine.setSelection(.all)
        _ = await engine.collectNow()
        #expect(await provider.selections.last == .all)
        await engine.shutdown()
    }
}

/// A provider that ignores cancellation and holds its result until a test releases it.
private actor StuckProvider: SystemMetricsProviding {
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        started += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            held.append(continuation)
        }
        return MockSystemMetricsProvider.sampleSnapshot
    }

    /// Releases every call still held, so none outlives the test.
    func releaseAll() {
        for continuation in held {
            continuation.resume()
        }
        held.removeAll()
    }
}

@Suite("Sampling engine: collections and overlap")
struct SamplingEngineCollectionTests {
    @Test func aProviderThatNeverReturnsCannotHoldTheEngine() async throws {
        let provider = StuckProvider()
        let engine = SamplingEngine(
            provider: provider,
            store: InMemorySnapshotStore(),
            collectionDeadline: .milliseconds(100)
        )
        let started = MonotonicTime.awakeSeconds()

        let update = await engine.collectNow()

        #expect(update.isFailure)
        #expect(MonotonicTime.awakeSeconds() - started < 5)

        let second = await engine.collectNow()
        #expect(second.isFailure)
        #expect(await provider.started == 2)
        await provider.releaseAll()
        await engine.shutdown()
    }

    @Test func aCollectionThatFinishesInTimeIsNotReportedAsTimedOut() async throws {
        let engine = SamplingEngine(
            provider: RecordingSystemProvider(),
            store: InMemorySnapshotStore(),
            collectionDeadline: .seconds(5)
        )
        #expect(await engine.collectNow().isFailure == false)
        await engine.shutdown()
    }

    @Test func collectionsNeverOverlap() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider(yields: 5)
        let engine = makeEngine(provider, scheduler)
        let subscription = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()

        await withTaskGroup(of: SamplingUpdate.self) { group in
            for _ in 0..<12 {
                group.addTask { await engine.collectNow() }
            }
            for await _ in group {}
        }
        scheduler.advance(by: 2)
        await scheduler.waitUntilSleeping()

        #expect(await provider.peakConcurrency == 1)
        #expect(await provider.calls == (await engine.completedCollections))
        withExtendedLifetime(subscription) {}
        await engine.shutdown()
    }

    @Test func overlappingRequestsJoinOneCollection() async throws {
        let provider = RecordingSystemProvider(yields: 5)
        let engine = SamplingEngine(provider: provider, store: InMemorySnapshotStore())

        let updates = await withTaskGroup(of: SamplingUpdate.self, returning: [SamplingUpdate].self) { group in
            for _ in 0..<20 {
                group.addTask { await engine.collectNow() }
            }
            var collected: [SamplingUpdate] = []
            for await update in group {
                collected.append(update)
            }
            return collected
        }

        #expect(updates.count == 20)
        #expect(await provider.calls < 20)
        #expect(await provider.peakConcurrency == 1)
        await engine.shutdown()
    }

    @Test func collectionsAreCountedOnlyWhenTheyComplete() async throws {
        let provider = RecordingSystemProvider()
        let engine = SamplingEngine(provider: provider, store: InMemorySnapshotStore())
        _ = await engine.collectNow()
        _ = await engine.collectNow()
        #expect(await engine.completedCollections == 2)
        #expect(await provider.calls == 2)
        await engine.shutdown()
    }

    @Test func failedCollectionsBackOffAndRecover() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider(failures: 3)
        let engine = makeEngine(provider, scheduler)
        let subscription = await engine.subscribe(interval: SamplingInterval(seconds: 1))
        var iterator = subscription.updates.makeAsyncIterator()

        await scheduler.waitUntilSleeping()
        #expect(try #require(await iterator.next()).isFailure)
        scheduler.advance(by: 2)
        await scheduler.waitUntilSleeping()
        #expect(try #require(await iterator.next()).isFailure)
        scheduler.advance(by: 4)
        await scheduler.waitUntilSleeping()
        #expect(try #require(await iterator.next()).isFailure)
        scheduler.advance(by: 8)
        await scheduler.waitUntilSleeping()
        #expect(try #require(await iterator.next()).isFailure == false)

        #expect(scheduler.requested == [2, 4, 8, 1])
        await engine.shutdown()
    }

    @Test func backoffIsCapped() {
        let wait = SamplingEngine.wait(for: SamplingInterval(seconds: 10), failures: 9, cap: 60)
        #expect(wait == .seconds(60))
    }
}

@Suite("Sampling engine: cadence and frequency")
struct SamplingEngineCadenceTests {
    @Test func frequencyChangeRestartsAtTheNewInterval() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        let subscription = await engine.subscribe(interval: SamplingInterval(seconds: 10))
        await scheduler.waitUntilSleeping()
        scheduler.advance(by: 10)
        await scheduler.waitUntilSleeping()

        await engine.setInterval(SamplingInterval(seconds: 1), for: subscription.id)
        await scheduler.waitUntilSleeping()
        scheduler.advance(by: 1)
        await scheduler.waitUntilSleeping()

        #expect(scheduler.requested == [10, 10, 1, 1])
        withExtendedLifetime(subscription) {}
        await engine.shutdown()
    }

    @Test func fastestSubscriberSetsTheLoopInterval() async throws {
        let scheduler = ManualScheduler()
        let engine = makeEngine(RecordingSystemProvider(), scheduler)
        let fast = await engine.subscribe(interval: .interactive)
        let background = await engine.subscribe(interval: .background)
        await scheduler.waitUntilSleeping()
        #expect(scheduler.requested.last == 2)
        #expect(await engine.effectiveInterval == SamplingInterval.interactive)

        await engine.unsubscribe(fast.id)
        await scheduler.waitUntilSleeping()
        #expect(scheduler.requested.last == 10)
        #expect(await engine.effectiveInterval == SamplingInterval.background)
        withExtendedLifetime(background) {}
        await engine.shutdown()
    }

    @Test func noSubscribersMeansNoLoopAndNoPolling() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider()
        let engine = makeEngine(provider, scheduler)
        #expect(await engine.isLoopRunning == false)
        scheduler.advance(by: 3_600)
        #expect(await provider.calls == 0)
        #expect(scheduler.requested.isEmpty)
    }

    @Test func intervalsAreClampedToSafeBounds() {
        #expect(SamplingInterval(seconds: 0.01).seconds == SamplingInterval.minimumSeconds)
        #expect(SamplingInterval(seconds: 1_000_000).seconds == SamplingInterval.maximumSeconds)
        #expect(SamplingInterval(seconds: .nan).seconds == SamplingInterval.minimumSeconds)
        #expect(SamplingInterval.interactive < SamplingInterval.background)
    }
}

@Suite("Sampling engine: sleep, wake, and termination")
struct SamplingEngineLifecycleTests {
    @Test func suspendStopsSchedulingAndWakeResetsBaselinesThenSamples() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider()
        let engine = makeEngine(provider, scheduler)
        let subscription = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()

        await engine.suspend()
        #expect(await engine.isLoopRunning == false)
        #expect(scheduler.sleeperCount == 0)
        let callsWhileAsleep = await provider.calls
        scheduler.advance(by: 600)
        #expect(await provider.calls == callsWhileAsleep)

        await engine.resume()
        await scheduler.waitUntilSleeping()
        #expect(await provider.resets == 1)
        #expect(await provider.calls == callsWhileAsleep + 1)
        #expect(await engine.isLoopRunning)
        withExtendedLifetime(subscription) {}
        await engine.shutdown()
    }

    @Test func aWallClockJumpBeyondTheAwakeClockIsTreatedAsSleep() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider()
        let wall = ClockBox()
        let awake = ClockBox()
        let engine = SamplingEngine(
            provider: provider,
            store: InMemorySnapshotStore(),
            scheduler: scheduler.scheduler,
            identity: { (Date(timeIntervalSince1970: wall.now), awake.now) }
        )
        _ = await engine.collectNow()
        wall.set(10)
        awake.set(10)
        _ = await engine.collectNow()
        #expect(await provider.resets == 0)

        wall.set(4_000)
        awake.set(11)
        _ = await engine.collectNow()
        #expect(await provider.resets == 1)
        await engine.shutdown()
    }

    @Test func sleepDetectionIgnoresNormalElapsedTime() {
        #expect(SamplingEngine.slept(wallDelta: 2, monotonicDelta: 2) == false)
        #expect(SamplingEngine.slept(wallDelta: 1_200, monotonicDelta: 2) == true)
    }

    @Test func shutdownFinishesSubscribersAndRefusesNewWork() async throws {
        let scheduler = ManualScheduler()
        let provider = RecordingSystemProvider()
        let engine = makeEngine(provider, scheduler)
        let subscription = await engine.subscribe(interval: .interactive)
        await scheduler.waitUntilSleeping()

        await engine.shutdown()
        var iterator = subscription.updates.makeAsyncIterator()
        var ended = false
        for _ in 0..<3 {
            if await iterator.next() == nil {
                ended = true
                break
            }
        }
        #expect(ended)
        #expect(await engine.isLoopRunning == false)
        let calls = await provider.calls
        #expect(await engine.collectNow().isFailure)
        #expect(await provider.calls == calls)
    }
}
