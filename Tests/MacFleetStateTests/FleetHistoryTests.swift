import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let historyNow = fleetEpoch

/// A store that keeps everything in memory, so the fleet tests exercise the real storage path.
private func historyStore() throws -> MetricHistoryStore {
    try MetricHistoryStore.inMemory()
}

/// Feeds a host's readings at the given arrival times. Each reading's CPU is `cpu`, and its clock reads `clockOffset`
/// seconds from this Mac's.
private func feed(
    _ store: MetricHistoryStore,
    host: HistoryHostID,
    arrivals: [TimeInterval],
    cpu: Double?,
    clockOffset: TimeInterval = 0
) async {
    for arrival in arrivals {
        let snapshot = fleetSnapshot(cpu: cpu ?? 0, at: Date(timeIntervalSince1970: arrival + clockOffset))
        let reading = cpu == nil ? withoutCPU(snapshot) : snapshot
        _ = await store.ingest(reading, from: host, receivedAt: Date(timeIntervalSince1970: arrival))
    }
    await store.flush()
}

private func withoutCPU(_ snapshot: RemoteSnapshot) -> RemoteSnapshot {
    RemoteSnapshot(
        capturedAt: snapshot.capturedAt,
        cpuTotal: .unavailable(.notSampled),
        memory: snapshot.memory,
        memoryPressure: snapshot.memoryPressure,
        storage: snapshot.storage,
        network: snapshot.network,
        thermal: snapshot.thermal,
        loadAverage: snapshot.loadAverage
    )
}

/// Arrival times in the hour before `historyNow`, ten seconds apart.
private func recentArrivals(count: Int = 30) -> [TimeInterval] {
    (0..<count).map { historyNow.timeIntervalSince1970 - 3_000 + Double($0) * 10 }
}

@MainActor
private func historyModel(
    _ store: MetricHistoryStore,
    identities: [HistoryHostIdentity],
    hostAlerts: HostAlertCenter? = nil
) -> FleetHistoryModel {
    FleetHistoryModel(store: store, identities: { identities }, hostAlerts: hostAlerts, now: { historyNow })
}

private let studioID = HistoryHostID.remote(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!)
private let miniID = HistoryHostID.remote(UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!)
private let laptopID = HistoryHostID.remote(UUID(uuidString: "00000000-0000-4000-8000-0000000000C3")!)

private let fleetIdentities = [
    HistoryHostIdentity(id: .local, label: "This Mac"),
    HistoryHostIdentity(id: studioID, label: "Studio"),
    HistoryHostIdentity(id: miniID, label: "Mini"),
    HistoryHostIdentity(id: laptopID, label: "Laptop"),
]

@MainActor
@Suite("Fleet history model: totals and comparison")
struct FleetHistoryModelTotalsTests {
    @Test func aFleetTotalMergesEachMacsOwnTotalsAndNamesThePeak() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.8)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.2)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()

        let aggregate = model.presentation.aggregate
        #expect(aggregate.coverage == "Data from 2 of 4 Macs in this range.")
        // Thirty readings of 0.8 and thirty of 0.2 merge to a mean of 0.5, with the peak on Studio.
        #expect(aggregate.lines[0] == "CPU: 50% average, 80% peak on Studio.")
        #expect(aggregate.lines[1].hasPrefix("Memory: 50% average"))
    }

    @Test func aMacWithoutAReadingLeavesTheTotalUntouchedRatherThanZero() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.6)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: nil)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        await model.select(miniID, true)

        let mini = try #require(model.presentation.comparison.first { $0.id == miniID })
        #expect(mini.samples == 30)
        #expect(mini.cpuAverage == "–", "no CPU reading is shown as a dash, not 0%")
        #expect(model.presentation.aggregate.lines[0] == "CPU: 60% average, 60% peak on Studio.")
    }

    @Test func aComparisonShowsEachSelectedMacOnItsOwnRow() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.9)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.1)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        await model.select(miniID, true)

        let rows = Dictionary(uniqueKeysWithValues: model.presentation.comparison.map { ($0.id, $0) })
        #expect(rows[studioID]?.cpuAverage == "90%")
        #expect(rows[miniID]?.cpuAverage == "10%")
        #expect(rows[studioID]?.title == "Studio")
        #expect(rows[miniID]?.title == "Mini")
    }

    @Test func noMoreThanFourMacsAreComparedAtOnce() async throws {
        let store = try historyStore()
        let model = historyModel(store, identities: fleetIdentities + [HistoryHostIdentity(id: HistoryHostID(rawValue: "fifth"), label: "Fifth")])
        await model.refresh()
        for identity in model.presentation.choices.map(\.id).prefix(4) {
            await model.select(identity, true)
        }
        #expect(model.selected.count == 4)
        await model.select(HistoryHostID(rawValue: "fifth"), true)
        #expect(model.selected.count == 4)
        #expect(model.notice?.contains("Compare up to 4 Macs") == true)
    }

    @Test func theChoicesCountOnlyStoredSamples() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(count: 12), cpu: 0.3)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        let choices = Dictionary(uniqueKeysWithValues: model.presentation.choices.map { ($0.id, $0) })
        #expect(choices[studioID]?.samples == 12)
        #expect(choices[miniID]?.samples == 0)
        #expect(choices[miniID]?.isSelected == false)
    }

    @Test func aHostWithADifferentClockIsNotedAndAlignedHostsAreNot() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.4, clockOffset: 5_400)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.4)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        await model.select(miniID, true)

        let rows = Dictionary(uniqueKeysWithValues: model.presentation.comparison.map { ($0.id, $0) })
        #expect(rows[studioID]?.clockNote?.contains("Its clock is 90 min ahead of this Mac's.") == true)
        #expect(rows[miniID]?.clockNote == nil)
        #expect(model.presentation.sections.first { $0.id == studioID }?.clockNote != nil)
    }

    @Test func theChartsOfEachSelectedMacHoldOnlyThatMacsData() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.7)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.05)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        await model.select(miniID, true)

        let studio = try #require(model.presentation.sections.first { $0.id == studioID })
        let cpuValues = studio.charts.first { $0.title == "CPU history" }?.series.first?.samples.compactMap { $0 } ?? []
        #expect(!cpuValues.isEmpty && cpuValues.allSatisfy { closeEnough($0, 0.7) })
        #expect(studio.hasData)
    }
}

@MainActor
@Suite("Fleet history model: removal, retention, and export")
struct FleetHistoryModelDataTests {
    @Test func deletingOneMacsHistoryLeavesTheOthersIntact() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.5)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.5)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()

        await model.deleteHistory(for: studioID)
        let choices = Dictionary(uniqueKeysWithValues: model.presentation.choices.map { ($0.id, $0) })
        #expect(choices[studioID]?.samples == 0)
        #expect(choices[miniID]?.samples == 30)
    }

    @Test func retentionIsSetPerMacAndCanReturnToTheDefault() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.5)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        #expect(model.presentation.retention?.isDefault == true)

        await model.setRetention(for: studioID, rawHours: 3, fiveMinuteDays: 4, hourlyDays: 10)
        let custom = try #require(model.presentation.retention)
        #expect(custom.isDefault == false)
        #expect(custom.rawHours == 3 && custom.fiveMinuteDays == 4 && custom.hourlyDays == 10)
        #expect(try await store.retention(for: miniID) == nil, "other Macs keep their own policy")

        await model.useDefaultRetention(for: studioID)
        #expect(model.presentation.retention?.isDefault == true)
    }

    @Test func aRetentionBelowTheMinimumIsRefusedWithAReason() async throws {
        let store = try historyStore()
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)
        await model.setRetention(for: studioID, rawHours: 1, fiveMinuteDays: 4, hourlyDays: 10)
        #expect(model.notice?.contains("could not be set") == true)
        #expect(try await store.retention(for: studioID) == nil)
    }

    @Test func theExportHoldsOnlyTheSelectedMacsAndLabelsEachRow() async throws {
        let store = try historyStore()
        await feed(store, host: studioID, arrivals: recentArrivals(), cpu: 0.25)
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: 0.75)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(studioID, true)

        let text = String(decoding: try await model.exportCSV(), as: UTF8.self)
        let lines = text.split(separator: "\n").dropFirst()
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.contains(",Studio,") })
        #expect(!text.contains("Mini"))
        let cpu = lines.filter { $0.contains(",cpu,") }
        #expect(cpu.allSatisfy { $0.contains(",0.25,") })
    }

    @Test func aGapInTheExportIsAnEmptyFieldNotZero() async throws {
        let store = try historyStore()
        await feed(store, host: miniID, arrivals: recentArrivals(), cpu: nil)
        let model = historyModel(store, identities: fleetIdentities)
        await model.refresh()
        await model.select(miniID, true)
        let text = String(decoding: try await model.exportCSV(), as: UTF8.self)
        let cpu = text.split(separator: "\n").first { $0.contains(",Mini,cpu,") }
        #expect(cpu?.contains(",,,0,") == true, "mean and maximum are empty and the observation count is zero")
    }

    @Test func aReportedProblemReachesTheWindow() async throws {
        let store = try historyStore()
        let model = historyModel(store, identities: fleetIdentities)
        model.report("The export could not be written.")
        #expect(model.presentation.notice == "The export could not be written.")
    }
}

@MainActor
@Suite("Fleet history presentation: wording")
struct FleetHistoryPresentationWordingTests {
    @Test func aClockNoteStatesTheDirectionAndThatPlacementIsByArrival() {
        let ahead = FleetHistoryPresentation.clockNote(.differs(seconds: 3_600))
        #expect(ahead == "Its clock is 60 min ahead of this Mac's. History is placed by arrival time, so it still lines up with the other Macs.")
        #expect(FleetHistoryPresentation.clockNote(.differs(seconds: -7_500))?.contains("Its clock is 2 h 5 min behind this Mac's.") == true)
        #expect(FleetHistoryPresentation.clockNote(.aligned) == nil)
        #expect(FleetHistoryPresentation.clockNote(.unknown) == nil)
    }

    @Test func aMacWithNoDataReadsAsNoDataInTheComparison() {
        let row = ComparisonRow.make(id: studioID, title: "Studio", summary: nil, clock: .unknown)
        #expect(row.samples == 0)
        #expect(row.lastSample == "No data")
        #expect(row.cpuAverage == "–")
    }

    @Test func theAggregateSaysWhenNoMacHasData() {
        let aggregate = FleetAggregatePresentation.make(summaries: [], labels: [:])
        #expect(aggregate.coverage == "Data from 0 of 0 Macs in this range.")
        #expect(aggregate.lines == ["No Mac has data in this range."])
    }

    @Test func theMinimumsAreStatedBesideTheRetentionSteppers() {
        let retention = RetentionPresentation.make(host: studioID, title: "Studio", policy: nil)
        #expect(retention.isDefault)
        #expect(retention.rawHours == 48)
        #expect(retention.minimumsText == "Minimums: raw 2 hours, five-minute 2 days, hourly 8 days.")
    }
}

@MainActor
@Suite("Host alerts: per Mac")
struct HostAlertCenterTests {
    @Test func oneMacsThresholdDoesNotChangeAnothersAlerts() async throws {
        let notifier = RecordingAlertNotifier(permission: .authorized)
        let center = HostAlertCenter(notifier: notifier, store: MemoryHostAlertSettingsStore())
        center.setThreshold(studioID, .highCPU, 50)
        center.setSustainedSeconds(studioID, .highCPU, 0)
        center.setSustainedSeconds(miniID, .highCPU, 0)

        // Both Macs report 70% CPU. Only Studio's threshold is 50%, so only Studio fires.
        center.evaluate(host: studioID, label: "Studio", snapshot: fleetSnapshot(cpu: 0.7), receivedAt: historyNow)
        center.evaluate(host: miniID, label: "Mini", snapshot: fleetSnapshot(cpu: 0.7), receivedAt: historyNow)
        try await fleetEventually { notifier.delivered.count == 1 }
        #expect(notifier.delivered.first?.title == "Studio: High CPU use")
        #expect(center.presentation(for: studioID).rows.first { $0.metric == .highCPU }?.statusText == "Firing now: High CPU use")
        #expect(center.presentation(for: miniID).rows.first { $0.metric == .highCPU }?.statusText == "Watching")
    }

    @Test func aNoticeNamesTheMacAndNothingIsPostedWithoutPermission() async throws {
        let notifier = RecordingAlertNotifier(permission: .notDetermined)
        let center = HostAlertCenter(notifier: notifier, store: MemoryHostAlertSettingsStore())
        center.setSustainedSeconds(studioID, .highCPU, 0)
        center.evaluate(host: studioID, label: "Studio", snapshot: fleetSnapshot(cpu: 0.95), receivedAt: historyNow)
        try await Task.sleep(for: .milliseconds(50))
        #expect(notifier.delivered.isEmpty)
        #expect(center.presentation(for: studioID).rows.first { $0.metric == .highCPU }?.lastAlertText?.contains("CPU is at 95%") == true)
    }

    @Test func settingsPersistPerMacAndComeBackAfterARestart() throws {
        let store = MemoryHostAlertSettingsStore()
        let first = HostAlertCenter(notifier: RecordingAlertNotifier(), store: store)
        first.setThreshold(studioID, .lowDiskSpace, 25)
        first.setEnabled(miniID, .highNetwork, false)

        let second = HostAlertCenter(notifier: RecordingAlertNotifier(), store: store)
        #expect(second.presentation(for: studioID).rows.first { $0.metric == .lowDiskSpace }?.threshold == 25)
        #expect(second.presentation(for: miniID).rows.first { $0.metric == .highNetwork }?.isEnabled == false)
        #expect(second.presentation(for: laptopID).rows.first { $0.metric == .lowDiskSpace }?.threshold == AlertMetric.lowDiskSpace.defaultThreshold)
    }

    @Test func removingAMacForgetsItsAlertSettings() throws {
        let store = MemoryHostAlertSettingsStore()
        let center = HostAlertCenter(notifier: RecordingAlertNotifier(), store: store)
        center.setThreshold(studioID, .highCPU, 60)
        center.remove(studioID)
        #expect(try store.load()[studioID.rawValue] == nil)
        #expect(center.presentation(for: studioID).rows.first { $0.metric == .highCPU }?.threshold == AlertMetric.highCPU.defaultThreshold)
    }

    @Test func aFailedSaveIsReportedNotHidden() {
        let center = HostAlertCenter(
            notifier: RecordingAlertNotifier(),
            store: MemoryHostAlertSettingsStore(saveFailure: CocoaError(.fileWriteNoPermission))
        )
        center.setThreshold(studioID, .highCPU, 60)
        #expect(center.notice?.contains("could not be saved") == true)
        #expect(center.presentation(for: studioID).notice == center.notice)
    }
}

@MainActor
@Suite("Fleet history ingestion from live watchers", .serialized)
struct FleetHistoryIngestionTests {
    /// A clock that moves forward ten seconds on each read. Each reading gets its own arrival time, as a live feed does.
    private final class AdvancingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = historyNow.timeIntervalSince1970 - 2_000

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            time += 10
            return Date(timeIntervalSince1970: time)
        }
    }

    @Test func concurrentWatchersWriteOnlyTheirOwnMacsRows() async throws {
        let store = try historyStore()
        let clock = AdvancingClock()
        let scheduling = RemoteScheduling(now: { clock.next() }, sleep: { _ in })
        let macs = [studioID, miniID, laptopID]
        var scripts: [UUID: [FleetScriptedSession]] = [:]
        var targets: [RemoteTarget] = []
        for (index, host) in macs.enumerated() {
            let recordID = UUID(uuidString: host.rawValue)!
            let record = fleetRecord(id: recordID, label: "Mac \(index)", pin: HostFingerprint(certificateDER: Data("pin \(index)".utf8)))
            targets.append(RemoteTarget(record: record, credential: try RemoteCredential(clientID: "laptop-1", secret: Data(repeating: 1, count: 32))))
            // Each Mac reports its own CPU, so any row that landed under the wrong Mac would show a different value.
            let readings = (0..<40).map { step in
                RemoteUpdate.snapshot(fleetSnapshot(cpu: Double(index + 1) / 10, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(step) * 10)))
            }
            scripts[recordID] = [.run([fleetConnected(name: "Mac \(index)", fingerprint: record.pinnedFingerprint)] + readings, end: .hold)]
        }
        let opener = FleetScriptedOpener(scripts)

        var watchers: [RemoteHostWatcher] = []
        for target in targets {
            watchers.append(RemoteHostWatcher(target: target, opener: opener, scheduling: scheduling, history: store))
        }
        await withTaskGroup(of: Void.self) { group in
            for watcher in watchers {
                group.addTask { await watcher.start() }
            }
        }
        // Wait until every Mac's readings have been taken in.
        let expected = targets
        try await fleetEventuallyAsync {
            var counts: [Int] = []
            for target in expected {
                // A read that fails counts as not yet, and the timeout reports the shortfall.
                let summary = try? await store.summary(
                    host: .remote(target.record.id),
                    from: Date(timeIntervalSince1970: 0),
                    to: Date(timeIntervalSince1970: 4_000_000_000)
                )
                counts.append(summary?.samples ?? 0)
            }
            return counts.allSatisfy { $0 >= 40 }
        }

        for (index, host) in macs.enumerated() {
            let summary = try await store.summary(host: host, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
            #expect(summary.samples == 40, "each Mac's readings arrive in full")
            #expect(closeEnough(summary.cpu.mean ?? -1, Double(index + 1) / 10), "\(host) holds only its own readings")
        }
        for watcher in watchers {
            await watcher.stop()
        }
    }

    @Test func removingAMacFromTheFleetDeletesItsStoredHistory() async throws {
        let store = try historyStore()
        let recordID = UUID(uuidString: studioID.rawValue)!
        let record = fleetRecord(id: recordID, label: "Studio", pin: HostFingerprint(certificateDER: Data("studio pin".utf8)))
        let secrets = MemoryAgentSecretStore(["remote.\(recordID.uuidString)": Data(repeating: 1, count: 32)])
        let opener = FleetScriptedOpener([recordID: [.run([
            fleetConnected(name: "Studio", fingerprint: record.pinnedFingerprint),
            .snapshot(fleetSnapshot(cpu: 0.4)),
        ], end: .hold)]])
        let fleet = FleetOverviewModel(
            store: MemoryRemoteHostStore(records: [record]),
            secrets: secrets,
            opener: opener,
            prober: FleetFakeProber([]),
            scheduling: RemoteScheduling(now: { fleetEpoch }, sleep: { _ in }),
            history: store
        )
        fleet.start()
        try await fleetEventually { fleet.statuses[recordID]?.snapshot != nil }
        try await fleetEventuallyAsync { (try? await store.storedHosts())?.contains(studioID) == true }

        fleet.remove(recordID)
        try await fleetEventuallyAsync { (try? await store.storedHosts())?.contains(studioID) == false }
        #expect(try await store.summary(host: studioID, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000)).samples == 0)
        await fleet.stopAll()
    }
}
