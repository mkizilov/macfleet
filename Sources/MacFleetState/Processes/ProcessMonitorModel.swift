import Foundation
import MacFleetKit
import Observation

/// Drives the process screen. Sampling runs only while the screen is open: `processesDidAppear` starts a watch loop
/// and `processesDidDisappear` stops it and waits, so nothing polls when the screen is closed.
@MainActor
@Observable
public final class ProcessMonitorModel {
    public private(set) var presentation: ProcessListPresentation
    public private(set) var sort = ProcessSortKey.cpu
    public private(set) var mode = ProcessListMode.processes
    public private(set) var searchText = ""

    private let monitor: ProcessMonitor
    private var interval: Duration
    private var snapshot: ProcessSnapshot?
    private var watcher: Task<Void, Never>?

    public init(monitor: ProcessMonitor, interval: Duration = .seconds(2)) {
        self.monitor = monitor
        self.interval = interval
        presentation = ProcessListPresentation(snapshot: nil, sort: .cpu, searchText: "", mode: .processes)
    }

    /// Starts sampling at `interval`. Calling it while already watching changes nothing.
    public func processesDidAppear() {
        guard watcher == nil else { return }
        watcher = Task { await self.watch() }
    }

    /// Stops sampling and returns once any sample in progress has finished.
    public func processesDidDisappear() async {
        let task = watcher
        watcher = nil
        task?.cancel()
        await task?.value
    }

    /// Changes the rate. A running watch loop uses it from its next wait.
    public func setInterval(_ interval: Duration) {
        self.interval = interval
    }

    /// Takes one sample now, outside the watch loop.
    public func refresh() async {
        apply(await monitor.sample())
    }

    public func setSort(_ key: ProcessSortKey) {
        sort = key
        rebuild()
    }

    public func setMode(_ newMode: ProcessListMode) {
        mode = newMode
        rebuild()
    }

    public func setSearchText(_ text: String) {
        searchText = text
        rebuild()
    }

    private func watch() async {
        while !Task.isCancelled {
            apply(await monitor.sample())
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private func apply(_ snapshot: ProcessSnapshot) {
        self.snapshot = snapshot
        rebuild()
    }

    private func rebuild() {
        presentation = ProcessListPresentation(snapshot: snapshot, sort: sort, searchText: searchText, mode: mode)
    }
}
