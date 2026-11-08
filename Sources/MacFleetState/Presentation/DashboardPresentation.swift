import Foundation
import MacFleetKit

public struct SummaryPresentation: Equatable, Sendable {
    public let hostName: String
    public let operatingSystem: String
    public let cpuCountText: String
    public let uptime: Readout
    public let load: Readout
    public let updatedText: String

    init(snapshot: SystemSnapshot) {
        hostName = snapshot.hostName
        operatingSystem = snapshot.operatingSystemVersion
        let cpus = snapshot.activeProcessorCount
        cpuCountText = "\(cpus) \(cpus == 1 ? "CPU" : "CPUs")"
        let uptimeText = SpokenFormatting.uptime(snapshot.uptimeSeconds)
        uptime = Readout(visible: uptimeText, spoken: uptimeText)
        let average = snapshot.loadAverage
        load = Readout(
            visible: [average.oneMinute, average.fiveMinutes, average.fifteenMinutes]
                .map(SpokenFormatting.load)
                .joined(separator: " · "),
            spoken: "Load averages \(SpokenFormatting.load(average.oneMinute)), \(SpokenFormatting.load(average.fiveMinutes)), and \(SpokenFormatting.load(average.fifteenMinutes)) over one, five, and fifteen minutes"
        )
        updatedText = "Updated \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))"
    }
}

/// Compact values for the menu bar. Unavailable values show a dash, never zero. Each metric has a short visible label and a
/// spoken phrase, so the label reads in full to VoiceOver.
public struct MenuBarPresentation: Equatable, Sendable {
    public let cpuText: String
    public let memoryText: String
    public let networkText: String
    public let diskText: String
    public let accessibilityLabel: String
    private let cpuSpoken: String
    private let memorySpoken: String
    private let networkSpoken: String
    private let diskSpoken: String

    init(cpu: Presented<UsageValue>, memory: Presented<UsageValue>, network: NetworkRate?, disk: Presented<UsageValue>) {
        cpuText = cpu.availableValue?.text ?? "–"
        memoryText = memory.availableValue?.text ?? "–"
        diskText = disk.availableValue?.text ?? "–"
        if let network {
            networkText = "↓\(ByteFormatting.compact(bytesPerSecond: network.receivedPerSecond)) ↑\(ByteFormatting.compact(bytesPerSecond: network.sentPerSecond))"
        } else {
            networkText = "↓– ↑–"
        }

        cpuSpoken = cpu.availableValue.map { "CPU \($0.spokenText)." } ?? "CPU unavailable."
        memorySpoken = memory.availableValue.map { "Memory \($0.spokenText)." } ?? "Memory unavailable."
        if let network {
            networkSpoken = "Download \(SpokenFormatting.rate(network.receivedPerSecond)), upload \(SpokenFormatting.rate(network.sentPerSecond))."
        } else {
            networkSpoken = "Network unavailable."
        }
        diskSpoken = disk.availableValue.map { "Startup disk \($0.spokenText)." } ?? "Startup disk unavailable."
        accessibilityLabel = ["MacFleet.", cpuSpoken, memorySpoken, networkSpoken].joined(separator: " ")
    }

    /// The item for one metric. The visible labels are short, so several metrics fit in the menu bar.
    func item(for metric: MenuBarMetric) -> MenuBarItem {
        switch metric {
        case .cpu: MenuBarItem(metric: .cpu, text: "CPU \(cpuText)", spokenText: cpuSpoken)
        case .memory: MenuBarItem(metric: .memory, text: "Mem \(memoryText)", spokenText: memorySpoken)
        case .network: MenuBarItem(metric: .network, text: networkText, spokenText: networkSpoken)
        case .disk: MenuBarItem(metric: .disk, text: "Disk \(diskText)", spokenText: diskSpoken)
        }
    }
}

/// The startup disk's use, read from the root volume. Missing values say why.
enum StartupDisk {
    static func presented(_ volumes: MetricReading<[VolumeMetrics]>) -> Presented<UsageValue> {
        switch volumes {
        case let .unavailable(issue):
            return .unavailable(issue.errorDescription ?? "Unavailable")
        case let .available(list):
            guard let root = list.first(where: { $0.mountPoint == "/" }) else {
                return .unavailable("The startup disk is not reported")
            }
            switch root.capacity {
            case let .available(capacity):
                return .available(UsageValue(fraction: capacity.utilization))
            case let .unavailable(issue):
                return .unavailable(issue.errorDescription ?? "Unavailable")
            }
        }
    }
}

public struct SourceItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let monitored: Bool
}

/// Everything the sources list needs. Toggle state comes from the selection the presentation was built with.
public struct SourcesPresentation: Equatable, Sendable {
    public let volumes: Presented<[SourceItem]>
    public let interfaces: Presented<[SourceItem]>

    init(snapshot: SystemSnapshot, selection: MonitoringSelection) {
        volumes = presented(snapshot.volumes) { list in
            list.map { volume in
                SourceItem(
                    id: volume.mountPoint,
                    title: volume.name,
                    detail: volume.mountPoint,
                    monitored: selection.monitorsVolume(at: volume.mountPoint)
                )
            }
        }
        interfaces = presented(snapshot.network) { list in
            list.map { interface in
                var details = [interface.isLoopback ? "Loopback" : (interface.isUp ? "Up" : "Down")]
                details.append(interface.ipv4Addresses.first ?? "No IPv4 address")
                return SourceItem(
                    id: interface.name,
                    title: interface.name,
                    detail: details.joined(separator: ", "),
                    monitored: selection.monitorsInterface(named: interface.name)
                )
            }
        }
    }
}

/// Everything the dashboard shows for one snapshot. Built once per sample, never inside a view body.
public struct DashboardPresentation: Equatable, Sendable {
    public let summary: SummaryPresentation
    public let menuBar: MenuBarPresentation
    public let cpu: CPUPresentation
    public let memory: MemoryPresentation
    public let storage: StoragePresentation
    public let network: NetworkPresentation
    public let sources: SourcesPresentation
    public let hardware: HardwarePresentation

    public init(snapshot: SystemSnapshot, history: MetricHistory, selection: MonitoringSelection) {
        summary = SummaryPresentation(snapshot: snapshot)
        cpu = CPUPresentation(reading: snapshot.cpu, cpuHistory: history.cpu)
        memory = MemoryPresentation(
            reading: snapshot.memory,
            pressure: snapshot.memoryPressure,
            memoryHistory: history.memory
        )
        storage = StoragePresentation(reading: snapshot.volumes)
        network = NetworkPresentation(reading: snapshot.network, history: history)
        sources = SourcesPresentation(snapshot: snapshot, selection: selection)
        hardware = HardwarePresentation(sample: snapshot.hardware)
        menuBar = MenuBarPresentation(
            cpu: cpu.total,
            memory: memory.usage,
            network: AggregateNetworkRate.rate(snapshot.network),
            disk: StartupDisk.presented(snapshot.volumes)
        )
    }
}
