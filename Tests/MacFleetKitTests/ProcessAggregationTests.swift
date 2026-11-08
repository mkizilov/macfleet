import Foundation
import Testing
@testable import MacFleetKit

private func makeRecord(
    pid: Int32,
    name: String? = "app",
    cpu: Double? = nil,
    memory: UInt64? = nil
) -> ProcessRecord {
    ProcessRecord(
        id: ProcessIdentity(pid: pid, startMicroseconds: 1_000_000),
        name: name.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: "Name not readable")),
        startDate: .available(Date(timeIntervalSince1970: 1)),
        cpuPercent: cpu.map { .available($0) } ?? .unavailable(.notSampled),
        footprintBytes: memory.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: "Not permitted"))
    )
}

@Suite("Process aggregation: sorting")
struct ProcessSortingTests {
    @Test func cpuSortsLargestFirstWithUnmeasuredLast() {
        let records = [
            makeRecord(pid: 1, cpu: nil, memory: 10),
            makeRecord(pid: 2, cpu: 5, memory: 10),
            makeRecord(pid: 3, cpu: 40, memory: 10),
        ]
        #expect(ProcessAggregation.sorted(records, by: .cpu).map(\.pid) == [3, 2, 1])
    }

    @Test func memorySortsLargestFirstAndBreaksTiesByPID() {
        let records = [
            makeRecord(pid: 9, cpu: 1, memory: 100),
            makeRecord(pid: 4, cpu: 1, memory: 300),
            makeRecord(pid: 2, cpu: 1, memory: 100),
            makeRecord(pid: 7, cpu: 1, memory: nil),
        ]
        #expect(ProcessAggregation.sorted(records, by: .memory).map(\.pid) == [4, 2, 9, 7])
    }

    @Test func theOrderDoesNotDependOnTheInputOrder() {
        let records = (1...50).map { makeRecord(pid: Int32($0), cpu: Double($0 % 5), memory: UInt64($0 % 3)) }
        let reversed = Array(records.reversed())
        #expect(ProcessAggregation.sorted(records, by: .cpu) == ProcessAggregation.sorted(reversed, by: .cpu))
        #expect(ProcessAggregation.sorted(records, by: .memory) == ProcessAggregation.sorted(reversed, by: .memory))
    }
}

@Suite("Process aggregation: search")
struct ProcessSearchTests {
    @Test func searchIsCaseInsensitiveAndIgnoresSurroundingSpaces() {
        let records = [
            makeRecord(pid: 1, name: "Safari"),
            makeRecord(pid: 2, name: "Terminal"),
            makeRecord(pid: 3, name: nil),
        ]
        #expect(ProcessAggregation.filtered(records, nameContaining: "  safa ").map(\.pid) == [1])
        #expect(ProcessAggregation.filtered(records, nameContaining: "").count == 3)
    }

    @Test func unreadableNamesNeverMatchASearch() {
        #expect(ProcessAggregation.filtered([makeRecord(pid: 1, name: nil)], nameContaining: "a").isEmpty)
    }
}

@Suite("Process aggregation: totals and groups")
struct ProcessTotalsTests {
    @Test func totalsCountOnlyReadingsThatExist() {
        let summary = ProcessAggregation.summary([
            makeRecord(pid: 1, cpu: 10, memory: 100),
            makeRecord(pid: 2, cpu: nil, memory: 300),
            makeRecord(pid: 3, cpu: nil, memory: nil),
        ])
        #expect(summary.processCount == 3)
        #expect(summary.readableCount == 2)
        #expect(summary.deniedCount == 1)
        #expect(summary.cpuMeasuredCount == 1)
        #expect(summary.totalCPUPercent == 10)
        #expect(summary.totalFootprintBytes == 400)
    }

    @Test func totalsAreNilWhenNothingWasRead() {
        let summary = ProcessAggregation.summary([makeRecord(pid: 1)])
        #expect(summary.readableCount == 0)
        #expect(summary.totalCPUPercent == nil)
        #expect(summary.totalFootprintBytes == nil)
    }

    @Test func groupsSumTheirMembersAndUnmeasuredGroupsSortLast() throws {
        let records = [
            makeRecord(pid: 1, name: "Chrome", cpu: 20, memory: 100),
            makeRecord(pid: 2, name: "Chrome", cpu: 5, memory: 50),
            makeRecord(pid: 3, name: "Finder", cpu: 30, memory: 10),
            makeRecord(pid: 4, name: nil, cpu: 50, memory: 1_000),
            makeRecord(pid: 5, name: "Chrome"),
            makeRecord(pid: 6, name: "Hidden"),
        ]

        let byCPU = ProcessAggregation.groups(records, by: .cpu)
        #expect(byCPU.map(\.name) == [nil, "Finder", "Chrome", "Hidden"])
        let chrome = try #require(byCPU.first(where: { $0.name == "Chrome" }))
        #expect(chrome.processCount == 3)
        #expect(chrome.readableCount == 2)
        #expect(chrome.deniedCount == 1)
        #expect(chrome.totalCPUPercent == 25)
        #expect(chrome.totalFootprintBytes == 150)
        #expect(byCPU.last?.totalCPUPercent == nil)

        #expect(ProcessAggregation.groups(records, by: .memory).map(\.name) == [nil, "Chrome", "Finder", "Hidden"])
    }
}
