import Foundation
import Testing
@testable import MacFleetKit

private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CPUTicks {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
}

private func vm(internalPages: UInt64 = 1_000) -> VMCounters {
    VMCounters(pageSize: 16_384, internalPages: internalPages, purgeablePages: 0, wiredPages: 0, compressedPages: 0)
}

@Suite("Process metrics provider with scripted counters")
struct ScriptedProviderTests {
    @Test func cpuNeedsTwoReadingsBeforeReportingUtilization() async throws {
        let counters = MockHostCounters(
            cpuTotal: [.success(ticks()), .success(ticks(user: 30, idle: 70))],
            perCoreCPU: [.success([ticks()]), .success([ticks(user: 30, idle: 70)])]
        )
        let provider = ProcessSystemMetricsProvider(counters: counters, minimumCPUWindow: 0)

        let first = try await provider.snapshot()
        #expect(first.cpu == .unavailable(.notSampled))

        let second = try await provider.snapshot()
        let cpu = try #require(second.cpu.availableValue)
        #expect(abs(cpu.total - 0.3) < 1e-12)
        #expect(cpu.perCore.availableValue?.count == 1)
    }

    @Test func memoryUsesPhysicalMemoryAsTotal() async throws {
        let provider = ProcessSystemMetricsProvider(
            counters: MockHostCounters(virtualMemory: [.success(vm())]),
            minimumCPUWindow: 0
        )
        let snapshot = try await provider.snapshot()
        let memory = try #require(snapshot.memory.availableValue)
        #expect(memory.totalBytes == snapshot.physicalMemoryBytes)
        #expect(memory.usedBytes + memory.availableBytes == snapshot.physicalMemoryBytes)
    }

    @Test func memoryFailureDoesNotAffectOtherReadings() async throws {
        let counters = MockHostCounters(
            cpuTotal: [.success(ticks()), .success(ticks(user: 1, idle: 1))],
            perCoreCPU: [.success([]), .success([])],
            virtualMemory: [.failure(.kernelCallFailed(call: "host_statistics64(HOST_VM_INFO64)", code: 4))],
            pressureLevel: [.success(1)]
        )
        let provider = ProcessSystemMetricsProvider(counters: counters, minimumCPUWindow: 0)
        _ = try await provider.snapshot()
        let snapshot = try await provider.snapshot()

        #expect(snapshot.memory == .unavailable(.kernelCallFailed(call: "host_statistics64(HOST_VM_INFO64)", code: 4)))
        #expect(snapshot.memoryPressure == .available(.normal))
        #expect(snapshot.cpu.availableValue != nil)
    }

    @Test func unrecognizedPressureLevelIsReported() async throws {
        let provider = ProcessSystemMetricsProvider(
            counters: MockHostCounters(pressureLevel: [.success(3)]),
            minimumCPUWindow: 0
        )
        let snapshot = try await provider.snapshot()
        #expect(snapshot.memoryPressure == .unavailable(.unrecognizedPressureLevel(3)))
    }

    @Test func perCoreFailureKeepsTotalCPU() async throws {
        let counters = MockHostCounters(
            cpuTotal: [.success(ticks()), .success(ticks(user: 40, idle: 60))],
            perCoreCPU: [.failure(.kernelCallFailed(call: "host_processor_info", code: 5))]
        )
        let provider = ProcessSystemMetricsProvider(counters: counters, minimumCPUWindow: 0)
        _ = try await provider.snapshot()
        let snapshot = try await provider.snapshot()

        let cpu = try #require(snapshot.cpu.availableValue)
        #expect(abs(cpu.total - 0.4) < 1e-12)
        #expect(cpu.perCore == .unavailable(.kernelCallFailed(call: "host_processor_info", code: 5)))
    }

    @Test func counterResetSurfacesAsCPUIssueAndRecovers() async throws {
        let counters = MockHostCounters(
            cpuTotal: [.success(ticks(user: 500)), .success(ticks(user: 10)), .success(ticks(user: 20, idle: 80))],
            perCoreCPU: [.success([]), .success([]), .success([])]
        )
        let provider = ProcessSystemMetricsProvider(counters: counters, minimumCPUWindow: 0)
        _ = try await provider.snapshot()
        let reset = try await provider.snapshot()
        #expect(reset.cpu == .unavailable(.counterReset))
        let next = try await provider.snapshot()
        let recovered = try #require(next.cpu.availableValue)
        #expect(abs(recovered.total - 1.0 / 9.0) < 1e-12)
    }
}

@Suite("Live Mach host metrics")
struct LiveHostMetricsTests {
    @Test func memoryReadingIsInternallyConsistent() async throws {
        let snapshot = try await ProcessSystemMetricsProvider(minimumCPUWindow: 0).snapshot()
        let memory = try #require(snapshot.memory.availableValue)
        #expect(memory.totalBytes == snapshot.physicalMemoryBytes)
        #expect(memory.usedBytes <= memory.totalBytes)
        #expect(memory.usedBytes + memory.availableBytes == memory.totalBytes)
    }

    @Test func memoryPressureIsReadable() async throws {
        let snapshot = try await ProcessSystemMetricsProvider(minimumCPUWindow: 0).snapshot()
        #expect(snapshot.memoryPressure.availableValue != nil)
    }

    @Test func firstLiveCPUReadingHasNoBaseline() async throws {
        let snapshot = try await ProcessSystemMetricsProvider(minimumCPUWindow: 0.2).snapshot()
        #expect(snapshot.cpu == .unavailable(.notSampled))
    }

    @Test func liveCPUUtilizationIsBoundedAndCoversEveryCore() async throws {
        let provider = ProcessSystemMetricsProvider(minimumCPUWindow: 0.2)
        _ = try await provider.snapshot()
        var reading = MetricReading<CPUUtilization>.unavailable(.notSampled)
        // The kernel publishes CPU ticks in batches about once a second, so a short window can be empty.
        for _ in 0..<10 where reading.availableValue == nil {
            try await Task.sleep(for: .milliseconds(300))
            reading = try await provider.snapshot().cpu
        }
        let cpu = try #require(reading.availableValue, "\(reading)")
        #expect((0...1).contains(cpu.total))
        let cores = try #require(cpu.perCore.availableValue)
        #expect(cores.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(cores.allSatisfy { (0...1).contains($0) })
    }
}
