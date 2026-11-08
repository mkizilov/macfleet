import Foundation
import MacFleetKit
import MacFleetState
import Testing

private func makeRecord(pid: Int32, name: String? = "Safari", cpu: Double? = nil, memory: UInt64? = nil) -> ProcessRecord {
    ProcessRecord(
        id: ProcessIdentity(pid: pid, startMicroseconds: 1_700_000_000_000_000),
        name: name.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: "Name not readable")),
        startDate: .available(Date(timeIntervalSince1970: 1_700_000_000)),
        cpuPercent: cpu.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: "Not permitted")),
        footprintBytes: memory.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: "Not permitted"))
    )
}

private func makeSnapshot(_ records: [ProcessRecord]) -> ProcessSnapshot {
    ProcessSnapshot(capturedAt: Date(timeIntervalSince1970: 0), records: .available(records))
}

@Suite("Process rows")
struct ProcessRowPresentationTests {
    @Test func readableRowShowsItsValues() {
        let row = ProcessRowPresentation(makeRecord(pid: 42, cpu: 12.34, memory: 1_073_741_824))
        #expect(row.pidText == "PID 42")
        #expect(row.cpu == .available("12.3%"))
        #expect(row.memory == .available(ByteFormatting.binary(bytes: 1_073_741_824)))
        #expect(row.isReadable)
    }

    @Test func deniedRowShowsReasonsInPlaceOfNumbers() {
        let row = ProcessRowPresentation(makeRecord(pid: 1, name: "launchd"))
        #expect(row.cpu == .unavailable("Not permitted"))
        #expect(row.memory == .unavailable("Not permitted"))
        #expect(!row.isReadable)
        #expect(row.spokenSummary.contains("CPU Not permitted"))
    }
}

@Suite("Process summary and groups")
struct ProcessTotalsPresentationTests {
    @Test func summaryNamesHowManyProcessesWereNotPermitted() {
        let summary = ProcessSummaryPresentation(ProcessAggregation.summary([
            makeRecord(pid: 1, cpu: 10, memory: 100),
            makeRecord(pid: 2, name: "launchd"),
        ]))
        #expect(summary.headline == "2 processes · 1 readable · 1 not permitted")
        #expect(summary.cpuText == "10.0% of one core across 1 measured")
        #expect(summary.memoryText == "\(ByteFormatting.binary(bytes: 100)) across 1 readable")
    }

    @Test func unmeasuredTotalsSayWhetherPermissionOrTimeIsMissing() {
        let denied = ProcessSummaryPresentation(ProcessAggregation.summary([makeRecord(pid: 1)]))
        #expect(denied.cpuText == "Not permitted by macOS")
        #expect(denied.memoryText == "Not permitted by macOS")

        let waiting = ProcessSummaryPresentation(ProcessAggregation.summary([makeRecord(pid: 2, memory: 5)]))
        #expect(waiting.cpuText == "Waiting for a second sample")
    }

    @Test func appGroupsShowTheirTotalsOrTheirReason() throws {
        let list = ProcessListPresentation(
            snapshot: makeSnapshot([
                makeRecord(pid: 1, name: "Chrome", memory: 10),
                makeRecord(pid: 2, name: "Hidden"),
            ]),
            sort: .cpu,
            searchText: "",
            mode: .apps
        )
        let chrome = try #require(list.groups.first(where: { $0.title == "Chrome" }))
        #expect(chrome.cpu == .unavailable("Waiting for a second sample"))
        #expect(chrome.memory == .available(ByteFormatting.binary(bytes: 10)))

        let hidden = try #require(list.groups.first(where: { $0.title == "Hidden" }))
        #expect(hidden.countText == "1 process, 0 readable")
        #expect(hidden.cpu == .unavailable("Not permitted by macOS"))
        #expect(hidden.memory == .unavailable("Not permitted by macOS"))
    }
}

@Suite("Process list presentation")
struct ProcessListPresentationTests {
    @Test func waitingAndFailedListingsSayWhyTheListIsEmpty() {
        let waiting = ProcessListPresentation(snapshot: nil, sort: .cpu, searchText: "", mode: .processes)
        #expect(waiting.status == "Waiting for the first process listing.")
        #expect(waiting.rows.isEmpty)
        #expect(waiting.summary == nil)

        let failed = ProcessSnapshot(
            capturedAt: Date(),
            records: .unavailable(.kernelCallFailed(call: "proc_listpids", code: 1))
        )
        let presentation = ProcessListPresentation(snapshot: failed, sort: .cpu, searchText: "", mode: .processes)
        #expect(presentation.status == "proc_listpids failed with code 1")
        #expect(presentation.rows.isEmpty)
    }

    @Test func searchNarrowsTheRowsAndTheTotalsTogether() {
        let list = ProcessListPresentation(
            snapshot: makeSnapshot([
                makeRecord(pid: 1, name: "Safari", cpu: 30, memory: 100),
                makeRecord(pid: 2, name: "Terminal", cpu: 5, memory: 50),
            ]),
            sort: .cpu,
            searchText: " safari ",
            mode: .processes
        )
        #expect(list.rows.map(\.pidText) == ["PID 1"])
        #expect(list.summary?.headline == "1 process · 1 readable")
        #expect(list.status == nil)
    }

    @Test func aSearchWithNoMatchNamesTheSearchAndShowsNoTotals() {
        let list = ProcessListPresentation(
            snapshot: makeSnapshot([makeRecord(pid: 1, name: "Safari", cpu: 30, memory: 100)]),
            sort: .cpu,
            searchText: "zzz",
            mode: .processes
        )
        #expect(list.status == "No process name contains “zzz”.")
        #expect(list.rows.isEmpty)
        #expect(list.summary == nil)
    }

    @Test func rowsFollowTheChosenSortKey() {
        let snapshot = makeSnapshot([
            makeRecord(pid: 1, cpu: 5, memory: 300),
            makeRecord(pid: 2, cpu: 50, memory: 100),
        ])
        let byCPU = ProcessListPresentation(snapshot: snapshot, sort: .cpu, searchText: "", mode: .processes)
        #expect(byCPU.rows.map(\.pidText) == ["PID 2", "PID 1"])
        let byMemory = ProcessListPresentation(snapshot: snapshot, sort: .memory, searchText: "", mode: .processes)
        #expect(byMemory.rows.map(\.pidText) == ["PID 1", "PID 2"])
    }
}
