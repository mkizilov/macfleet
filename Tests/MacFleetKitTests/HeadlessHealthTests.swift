import Foundation
import Testing
@testable import MacFleetKit

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func health(
    state: AgentState = .running,
    listener: ListenerState = .disabled(reason: "none"),
    interval: Double = 10,
    updatedAgo: Double = 0,
    sampledAgo: Double? = 0
) -> HeadlessHealth {
    HeadlessHealth(
        state: state,
        listener: listener,
        samplingIntervalSeconds: interval,
        lastSampleAt: sampledAgo.map { now.addingTimeInterval(-$0) },
        startedAt: now.addingTimeInterval(-600),
        updatedAt: now.addingTimeInterval(-updatedAgo),
        processID: 4242,
        version: HeadlessAgent.version
    )
}

@Suite("Headless health")
struct HeadlessHealthTests {
    @Test func aRunningAgentWithAFreshSampleIsHealthy() {
        #expect(HeadlessHealthEvaluation.verdict(health(), now: now) == .healthy)
    }

    @Test func aListeningAgentIsHealthyWhileItsListenerIsUp() {
        let listening = health(listener: .listening(address: "127.0.0.1", port: 21440))
        #expect(HeadlessHealthEvaluation.verdict(listening, now: now) == .healthy)
    }

    @Test func anAgentThatIsNotRunningIsUnhealthy() {
        #expect(HeadlessHealthEvaluation.verdict(health(state: .stopped), now: now) == .unhealthy(reason: "the agent is stopped"))
        #expect(HeadlessHealthEvaluation.verdict(health(state: .starting), now: now) == .unhealthy(reason: "the agent is starting"))
    }

    @Test func aFailedListenerIsUnhealthyWithItsReason() {
        let failed = health(listener: .failed(reason: "address not assigned"))
        #expect(HeadlessHealthEvaluation.verdict(failed, now: now) == .unhealthy(reason: "the listener failed: address not assigned"))
    }

    @Test func aStaleStatusFileMeansTheAgentMayNotBeRunning() {
        let stale = health(updatedAgo: 120)
        #expect(HeadlessHealthEvaluation.verdict(stale, now: now) == .unhealthy(
            reason: "the status file is stale, so the agent may not be running"
        ))
    }

    @Test func aSampleOlderThanTheLimitIsUnhealthy() {
        let old = health(sampledAgo: 45)
        #expect(HeadlessHealthEvaluation.verdict(old, now: now) == .unhealthy(reason: "the last sample is older than 30 seconds"))
    }

    @Test func noSampleYetIsUnhealthy() {
        #expect(HeadlessHealthEvaluation.verdict(health(sampledAgo: nil), now: now) == .unhealthy(reason: "no sample has been taken yet"))
    }

    @Test func theSampleLimitScalesWithTheIntervalAndHasAFloor() {
        #expect(HeadlessHealthEvaluation.maximumSampleAge(samplingIntervalSeconds: 2) == 30)
        #expect(HeadlessHealthEvaluation.maximumSampleAge(samplingIntervalSeconds: 60) == 180)
    }

    @Test func aStatusReportRoundTripsAndIsReplacedAtomically() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("status.json").path
        #expect(try HeadlessStatusFile.read(from: path) == nil)

        let first = health(listener: .listening(address: "127.0.0.1", port: 21440))
        try HeadlessStatusFile.write(first, to: path)
        #expect(try HeadlessStatusFile.read(from: path) == first)

        let second = health(state: .stopped)
        try HeadlessStatusFile.write(second, to: path)
        #expect(try HeadlessStatusFile.read(from: path) == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["status.json"])
    }
}
