import Testing
@testable import MacFleetKit

@Suite("Memory usage calculation")
struct MemoryUsageCalculatorTests {
    private let pageSize: UInt64 = 16_384
    private let totalBytes: UInt64 = 1 << 30

    @Test func usedMemoryFollowsActivityMonitorBreakdown() throws {
        let counters = VMCounters(
            pageSize: pageSize,
            internalPages: 1_000,
            purgeablePages: 100,
            wiredPages: 200,
            compressedPages: 50
        )
        let usage = try MemoryUsageCalculator.usage(from: counters, totalBytes: totalBytes)
        #expect(usage.usedBytes == 1_150 * pageSize)
        #expect(usage.totalBytes == totalBytes)
        #expect(usage.availableBytes == totalBytes - 1_150 * pageSize)
        #expect(usage.usedBytes + usage.availableBytes == usage.totalBytes)
    }

    @Test func purgeableAboveInternalIsInconsistent() {
        let counters = VMCounters(
            pageSize: pageSize,
            internalPages: 10,
            purgeablePages: 20,
            wiredPages: 0,
            compressedPages: 0
        )
        #expect(throws: MetricIssue.inconsistentMemoryAccounting) {
            try MemoryUsageCalculator.usage(from: counters, totalBytes: totalBytes)
        }
    }

    @Test func usedAboveTotalIsInconsistent() {
        let counters = VMCounters(
            pageSize: pageSize,
            internalPages: 100_000,
            purgeablePages: 0,
            wiredPages: 0,
            compressedPages: 0
        )
        #expect(throws: MetricIssue.inconsistentMemoryAccounting) {
            try MemoryUsageCalculator.usage(from: counters, totalBytes: 1 << 20)
        }
    }

    @Test func zeroUsageLeavesEverythingAvailable() throws {
        let counters = VMCounters(pageSize: pageSize, internalPages: 0, purgeablePages: 0, wiredPages: 0, compressedPages: 0)
        let usage = try MemoryUsageCalculator.usage(from: counters, totalBytes: totalBytes)
        #expect(usage.usedBytes == 0)
        #expect(usage.availableBytes == totalBytes)
    }
}

@Suite("Memory pressure levels")
struct MemoryPressureLevelTests {
    @Test func rawValuesMatchKernelLevels() {
        #expect(MemoryPressureLevel(rawValue: 1) == .normal)
        #expect(MemoryPressureLevel(rawValue: 2) == .warning)
        #expect(MemoryPressureLevel(rawValue: 4) == .critical)
    }

    @Test func unknownRawValueHasNoLevel() {
        #expect(MemoryPressureLevel(rawValue: 3) == nil)
        #expect(MemoryPressureLevel(rawValue: 0) == nil)
    }
}
