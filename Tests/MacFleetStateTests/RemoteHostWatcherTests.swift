import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let watcherFingerprint = HostFingerprint(certificateDER: Data("watcher host".utf8))

private func watcherTarget(id: UUID = UUID()) throws -> RemoteTarget {
    RemoteTarget(
        record: fleetRecord(id: id, label: "Studio", pin: watcherFingerprint),
        credential: try RemoteCredential(clientID: "laptop-1", secret: Data(repeating: 4, count: 32))
    )
}

/// Collects statuses until `done` says stop. Each one is recorded in order.
private func collect(
    _ watcher: RemoteHostWatcher,
    until done: (RemoteConnectionState) async -> Bool
) async -> [RemoteConnectionState] {
    var states: [RemoteConnectionState] = []
    for await status in watcher.statuses {
        states.append(status.state)
        if await done(status.state) { break }
    }
    return states
}

@Suite("Remote host watcher: connection and retries")
struct RemoteHostWatcherRetryTests {
    @Test func aHealthySessionPublishesConnectionThenEverySnapshot() async throws {
        let target = try watcherTarget()
        let first = fleetSnapshot(cpu: 0.10)
        let second = fleetSnapshot(cpu: 0.20)
        let opener = FleetScriptedOpener([target.record.id: [.run([
            fleetConnected(name: "Studio", fingerprint: watcherFingerprint),
            .snapshot(first),
            .snapshot(second),
        ], end: .hold)]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        var last: RemoteHostStatus?
        for await status in watcher.statuses {
            last = status
            if status.snapshot == second { break }
        }
        #expect(last?.state == .online)
        #expect(last?.hostName == "Studio")
        #expect(last?.capabilities == RemoteSnapshot.allSupportedCapabilities)
        #expect(last?.snapshot == second)
        #expect(last?.receivedAt == fleetEpoch)
        #expect(await scheduler.requested.isEmpty)
        await watcher.stop()
    }

    @Test func aTransientFailureRetriesWithDoublingDelaysUntilTheHostAnswers() async throws {
        let target = try watcherTarget()
        let id = target.record.id
        let opener = FleetScriptedOpener([id: [
            .fail(.connectionFailed("refused")),
            .fail(.connectionFailed("refused")),
            .fail(.connectionFailed("refused")),
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .hold),
        ]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        let states = await collect(watcher) { state in
            if case .reconnecting = state {
                _ = await scheduler.awaitPending(atLeast: 1)
                await scheduler.fire()
            }
            if case .online = state { return true }
            return false
        }

        let attempts = states.compactMap { state -> Int? in
            if case let .reconnecting(attempt, _, _) = state { return attempt }
            return nil
        }
        #expect(attempts == [1, 2, 3])
        #expect(states.last == .online)
        #expect(await scheduler.requested == [.seconds(2), .seconds(4), .seconds(8)])
        #expect(await opener.attempts[id] == 4)
        await watcher.stop()
    }

    @Test func aReconnectingStatusNamesTheRetryTimeAndTheReason() async throws {
        let target = try watcherTarget()
        let opener = FleetScriptedOpener([target.record.id: [.fail(.connectionFailed("no route")), .run([], end: .hold)]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        var reconnecting: RemoteConnectionState?
        for await status in watcher.statuses {
            if case .reconnecting = status.state {
                reconnecting = status.state
                break
            }
        }
        guard case let .reconnecting(attempt, retryAt, failure)? = reconnecting else {
            Issue.record("expected a reconnecting state")
            await watcher.stop()
            return
        }
        #expect(attempt == 1)
        #expect(retryAt == fleetEpoch.addingTimeInterval(2))
        #expect(failure == .unreachable("no route"))
        await watcher.stop()
    }

    @Test func aWrongSecretStopsTheRetriesAtOnce() async throws {
        let target = try watcherTarget()
        let opener = FleetScriptedOpener([target.record.id: [
            .fail(.hostRejected(RemoteProtocolError(code: .authenticationFailed, message: "no", retryable: false))),
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .hold),
        ]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        let states = await collect(watcher) { state in
            if case .stopped = state { return true }
            return false
        }
        #expect(states.last == .stopped(.authenticationFailed))
        #expect(await scheduler.requested.isEmpty)
        #expect(await opener.attempts[target.record.id] == 1)
        await watcher.stop()
    }

    @Test func aChangedCertificateStopsAndNamesTheCertificateShown() async throws {
        let target = try watcherTarget()
        let shown = HostFingerprint(certificateDER: Data("replacement".utf8))
        let opener = FleetScriptedOpener([target.record.id: [.fail(.identityMismatch(presented: shown))]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        let states = await collect(watcher) { state in
            if case .stopped = state { return true }
            return false
        }
        #expect(states.last == .stopped(.identityChanged(presented: shown)))
        #expect(await scheduler.requested.isEmpty)
        await watcher.stop()
    }

    @Test func aUnavailableHostKeepsRetryingWithGrowingDelays() async throws {
        let target = try watcherTarget()
        let failures = Array(repeating: FleetScriptedSession.fail(.connectionFailed("refused")), count: 6)
        let opener = FleetScriptedOpener([target.record.id: failures + [
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .hold),
        ]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        _ = await collect(watcher) { state in
            if case .reconnecting = state {
                _ = await scheduler.awaitPending(atLeast: 1)
                await scheduler.fire()
            }
            if case .online = state { return true }
            return false
        }
        #expect(await scheduler.requested == [2, 4, 8, 16, 32, 64].map { Duration.seconds($0) })
        await watcher.stop()
    }

    @Test func aDroppedSessionReconnectsAfterTheBaseDelayBecauseItWasOnline() async throws {
        let target = try watcherTarget()
        let opener = FleetScriptedOpener([target.record.id: [
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .fail(.timedOut)),
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .hold),
        ]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        _ = await collect(watcher) { state in
            if case .reconnecting = state {
                _ = await scheduler.awaitPending(atLeast: 1)
                await scheduler.fire()
            }
            if case .online = state, await opener.attempts[target.record.id] == 2 { return true }
            return false
        }
        #expect(await scheduler.requested == [.seconds(2)])
        await watcher.stop()
    }

    @Test func stoppingDuringAWaitOpensNoFurtherSession() async throws {
        let target = try watcherTarget()
        let id = target.record.id
        let opener = FleetScriptedOpener([id: [
            .fail(.connectionFailed("refused")),
            .run([fleetConnected(name: "Studio", fingerprint: watcherFingerprint)], end: .hold),
        ]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()
        _ = await collect(watcher) { state in
            if case .reconnecting = state { return true }
            return false
        }
        #expect(await scheduler.awaitPending(atLeast: 1))

        await watcher.stop()
        #expect(await opener.attempts[id] == 1)
    }

    @Test func stoppingAnOnlineWatcherEndsItsStream() async throws {
        let target = try watcherTarget()
        let opener = FleetScriptedOpener([target.record.id: [.run([
            fleetConnected(name: "Studio", fingerprint: watcherFingerprint),
        ], end: .hold)]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.start()

        let states = await collect(watcher) { state in
            if case .online = state { return true }
            return false
        }
        #expect(states.last == .online)
        await watcher.stop()

        var afterStop = 0
        for await _ in watcher.statuses {
            afterStop += 1
        }
        #expect(afterStop == 0)
        #expect(await opener.attempts[target.record.id] == 1)
    }

    @Test func aStoppedWatcherNeverStartsAgain() async throws {
        let target = try watcherTarget()
        let opener = FleetScriptedOpener([target.record.id: [.run([], end: .hold)]])
        let scheduler = FleetManualScheduler()
        let watcher = RemoteHostWatcher(target: target, opener: opener, scheduling: fleetScheduling(scheduler))
        await watcher.stop()
        await watcher.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await opener.attempts[target.record.id] == nil)
    }
}

@Suite("Remote failure classification and backoff")
struct RemoteFailureTests {
    @Test func transientFailuresAreRetriedAndFatalOnesAreNot() {
        #expect(!RemoteFailure.unreachable("x").isFatal)
        #expect(!RemoteFailure.timedOut.isFatal)
        #expect(!RemoteFailure.hostRestarting.isFatal)
        #expect(!RemoteFailure.hostError("x").isFatal)
        #expect(!RemoteFailure.closed.isFatal)
        #expect(RemoteFailure.authenticationFailed.isFatal)
        #expect(RemoteFailure.identityChanged(presented: nil).isFatal)
        #expect(RemoteFailure.certificateRejected(reason: "expired").isFatal)
        #expect(RemoteFailure.hostNotProven.isFatal)
        #expect(RemoteFailure.versionMismatch(supported: []).isFatal)
        #expect(RemoteFailure.protocolError("x").isFatal)
        #expect(RemoteFailure.credentialMissing.isFatal)
        #expect(RemoteFailure.invalidAddress.isFatal)
    }

    @Test func everyClientErrorMapsOntoOneFailure() {
        let refused = RemoteProtocolError(code: .authenticationFailed, message: "no", retryable: false)
        #expect(RemoteFailure(RemoteClientError.connectionFailed("x")) == .unreachable("x"))
        #expect(RemoteFailure(RemoteClientError.timedOut) == .timedOut)
        #expect(RemoteFailure(RemoteClientError.closed) == .closed)
        #expect(RemoteFailure(RemoteClientError.identityMismatch(presented: nil)) == .identityChanged(presented: nil))
        #expect(RemoteFailure(RemoteClientError.certificateRejected(reason: "expired")) == .certificateRejected(reason: "expired"))
        #expect(RemoteFailure(RemoteClientError.hostNotAuthenticated) == .hostNotProven)
        #expect(RemoteFailure(RemoteClientError.protocolViolation("bad")) == .protocolError("bad"))
        #expect(RemoteFailure(RemoteClientError.invalidEndpoint) == .invalidAddress)
        #expect(RemoteFailure(RemoteClientError.hostRejected(refused)) == .authenticationFailed)
        #expect(RemoteFailure(RemoteClientError.hostRejected(RemoteProtocolError(
            code: .shuttingDown, message: "bye", retryable: true
        ))) == .hostRestarting)
        #expect(RemoteFailure(RemoteClientError.hostRejected(RemoteProtocolError(
            code: .unsupportedVersion, message: "no", retryable: false, supportedVersions: [RemoteProtocol.current]
        ))) == .versionMismatch(supported: [RemoteProtocol.current]))
        #expect(RemoteFailure(RemoteClientError.hostRejected(RemoteProtocolError(
            code: .unrecognized, message: "new code", retryable: true
        ))) == .hostError("new code"))
        #expect(RemoteFailure(RemoteClientError.hostRejected(RemoteProtocolError(
            code: .malformedMessage, message: "garbled", retryable: false
        ))) == .protocolError("garbled"))
    }

    @Test func anUnclassifiedErrorIsTreatedAsTransient() {
        #expect(!RemoteFailure(CocoaError(.fileReadNoSuchFile)).isFatal)
    }

    @Test func theBackoffDoublesFromTheBaseAndNeverPassesTheCap() {
        let backoff = RemoteBackoff.standard
        #expect(backoff.delay(afterFailures: 1) == .seconds(2))
        #expect(backoff.delay(afterFailures: 2) == .seconds(4))
        #expect(backoff.delay(afterFailures: 7) == .seconds(128))
        #expect(backoff.delay(afterFailures: 8) == .seconds(256))
        #expect(backoff.delay(afterFailures: 9) == .seconds(300))
        #expect(backoff.delay(afterFailures: 500) == .seconds(300))
        #expect(backoff.delay(afterFailures: 0) == .seconds(2))
    }
}
