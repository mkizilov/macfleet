import Foundation
import Testing
@testable import MacFleetKit

/// A CPU section that never returns in time. It honors cancellation, as well-behaved sections should.
private struct HangingCPUProvider: MetricProvider {
    typealias Output = CPUUtilization

    func sample(_ context: SampleContext) async -> MetricReading<CPUUtilization> {
        try? await Task.sleep(for: .seconds(60))
        return .unavailable(.notSampled)
    }
}

private struct UnavailableLoadProvider: MetricProvider {
    typealias Output = LoadAverage

    func sample(_ context: SampleContext) async -> MetricReading<LoadAverage> {
        .unavailable(.notProvided(resource: "load averages"))
    }
}

/// Records the context it is handed, so tests can check that every section gets the same one.
private actor ContextRecorder: MetricProvider {
    typealias Output = CPUUtilization

    private(set) var contexts: [SampleContext] = []

    func sample(_ context: SampleContext) -> MetricReading<CPUUtilization> {
        contexts.append(context)
        return .unavailable(.notSampled)
    }
}

private func cpu(user: UInt32, idle: UInt32) -> CPUTicks {
    CPUTicks(user: user, system: 0, idle: idle, nice: 0)
}

private func sections(
    cpu: any MetricProvider<CPUUtilization> = CPUMetricProvider(counters: MockHostCounters()),
    load: any MetricProvider<LoadAverage> = LoadAverageMetricProvider()
) -> ProcessSystemMetricsProvider.Sections {
    ProcessSystemMetricsProvider.Sections(
        cpu: cpu,
        memory: MemoryUsageMetricProvider(
            counters: MockHostCounters(virtualMemory: [.success(VMCounters(
                pageSize: 16_384,
                internalPages: 1_000,
                purgeablePages: 0,
                wiredPages: 0,
                compressedPages: 0
            ))]),
            totalBytes: 1 << 30
        ),
        pressure: MemoryPressureMetricProvider(counters: MockHostCounters(pressureLevel: [.success(1)])),
        storage: StorageMetricProvider(volumes: MockVolumeSource([.success([])])),
        network: NetworkMetricProvider(interfaces: MockInterfaceSource([.success([])])),
        load: load
    )
}

@Suite("Section composition")
struct SectionCompositionTests {
    @Test func hangingSectionTimesOutWhileTheOthersStillReport() async throws {
        let provider = ProcessSystemMetricsProvider(
            sections: sections(cpu: HangingCPUProvider()),
            clock: { 0 },
            sampleTimeout: .milliseconds(50)
        )
        let started = MonotonicTime.awakeSeconds()

        let snapshot = try await provider.snapshot(selection: .all)

        #expect(snapshot.cpu == .unavailable(.timedOut))
        #expect(snapshot.memory.availableValue?.totalBytes == 1 << 30)
        #expect(snapshot.memoryPressure == .available(.normal))
        #expect(MonotonicTime.awakeSeconds() - started < 5)
    }

    @Test func missingLoadAverageStillFailsTheWholeSnapshot() async throws {
        let provider = ProcessSystemMetricsProvider(
            sections: sections(load: UnavailableLoadProvider()),
            clock: { 0 },
            sampleTimeout: .seconds(2)
        )
        await #expect(throws: MetricsError.loadAverageUnavailable) {
            try await provider.snapshot(selection: .all)
        }
    }

    @Test func everySectionReceivesTheSameTimestampAndSelection() async throws {
        let recorder = ContextRecorder()
        let provider = ProcessSystemMetricsProvider(
            sections: sections(cpu: recorder),
            clock: { 42.5 },
            sampleTimeout: .seconds(2)
        )
        let snapshot = try await provider.snapshot(selection: .all)

        let contexts = await recorder.contexts
        #expect(contexts.count == 1)
        #expect(contexts.first?.monotonicSeconds == 42.5)
        #expect(contexts.first?.selection == MonitoringSelection.all)
        #expect(contexts.first?.wallClock == snapshot.capturedAt)
    }

    @Test func resettingBaselinesRestartsTheCPUWindow() async throws {
        let clock = ClockBox()
        let provider = ProcessSystemMetricsProvider(
            counters: MockHostCounters(
                cpuTotal: [
                    .success(cpu(user: 0, idle: 0)),
                    .success(cpu(user: 30, idle: 70)),
                    .success(cpu(user: 60, idle: 140)),
                ],
                perCoreCPU: [.success([]), .success([]), .success([])]
            ),
            volumes: MockVolumeSource([.success([])]),
            interfaces: MockInterfaceSource([.success([])]),
            minimumCPUWindow: 1,
            clock: { clock.now },
            sampleTimeout: .seconds(2)
        )

        clock.set(0)
        #expect(try await provider.snapshot(selection: .all).cpu == .unavailable(.notSampled))
        clock.set(2)
        #expect(try await provider.snapshot(selection: .all).cpu.availableValue?.total == 0.3)

        await provider.resetBaselines()
        clock.set(4)
        #expect(try await provider.snapshot(selection: .all).cpu == .unavailable(.notSampled))
    }
}
