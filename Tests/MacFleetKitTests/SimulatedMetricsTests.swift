import Foundation
import Testing
@testable import MacFleetKit

@Suite("Simulated metrics")
struct SimulatedMetricsTests {
    private func sequence(seed: UInt64, steps: Int) -> [SystemSnapshot] {
        var timeline = SimulatedMetricsTimeline(seed: seed)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<steps).map { index in
            timeline.nextSnapshot(
                selection: .default,
                capturedAt: start.addingTimeInterval(Double(index) * SimulatedMetricsTimeline.stepSeconds)
            )
        }
    }

    @Test func sameSeedProducesTheSameSequence() {
        #expect(sequence(seed: 9, steps: 50) == sequence(seed: 9, steps: 50))
    }

    @Test func differentSeedsProduceDifferentCPULoad() {
        let first = sequence(seed: 1, steps: 20).compactMap { $0.cpu.availableValue?.total }
        let second = sequence(seed: 2, steps: 20).compactMap { $0.cpu.availableValue?.total }
        #expect(first != second)
    }

    @Test func readingsStayInTheirPhysicalRanges() {
        for snapshot in sequence(seed: 42, steps: 400) {
            if let cpu = snapshot.cpu.availableValue {
                #expect((0...1).contains(cpu.total))
                #expect(cpu.perCore.availableValue?.allSatisfy { (0...1).contains($0) } == true)
            }
            if let memory = snapshot.memory.availableValue {
                #expect(memory.usedBytes + memory.availableBytes == memory.totalBytes)
            }
            for volume in snapshot.volumes.availableValue ?? [] {
                if let capacity = volume.capacity.availableValue {
                    #expect(capacity.availableBytes <= capacity.totalBytes)
                }
            }
            for interface in snapshot.network.availableValue ?? [] {
                if let rate = interface.rates.availableValue {
                    #expect(rate.receivedPerSecond >= 0)
                    #expect(rate.sentPerSecond >= 0)
                }
            }
        }
    }

    @Test func countersOnlyGrow() {
        let snapshots = sequence(seed: 5, steps: 100)
        let received = snapshots.compactMap { snapshot in
            snapshot.network.availableValue?.first { $0.name == "en0" }?.totals.availableValue?.bytesReceived
        }
        #expect(received.count == 100)
        #expect(zip(received, received.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
    }

    @Test func includesAnOccasionalUnavailableCPUReadingToExerciseGaps() {
        let gaps = sequence(seed: 42, steps: 200).filter { $0.cpu.availableValue == nil }
        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0.cpu == .unavailable(.noElapsedTicks) })
    }

    @Test func excludedSourcesAreReportedAsNotMonitored() {
        var timeline = SimulatedMetricsTimeline(seed: 3)
        let snapshot = timeline.nextSnapshot(selection: .default, capturedAt: Date())
        let loopback = snapshot.network.availableValue?.first { $0.name == "lo0" }
        #expect(loopback?.totals == .unavailable(.notMonitored))
        #expect(loopback?.rates == .unavailable(.notMonitored))
    }

    @Test func providerServesTheSameTimelineThroughTheProtocol() async throws {
        let provider = SimulatedSystemMetricsProvider(seed: 42, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let first = try await provider.snapshot()
        #expect(first.hostName == "macfleet-preview.local")
        #expect(first.volumes.availableValue?.first?.mountPoint == "/")
    }
}
