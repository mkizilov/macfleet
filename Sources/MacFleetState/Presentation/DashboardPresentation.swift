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

/// Compact values for the menu bar. Unavailable values show a dash, never zero.
public struct MenuBarPresentation: Equatable, Sendable {
    public let cpuText: String
    public let memoryText: String
    public let networkText: String
    public let accessibilityLabel: String

    init(cpu: Presented<UsageValue>, memory: Presented<UsageValue>, network: NetworkRate?) {
        cpuText = cpu.availableValue?.text ?? "–"
        memoryText = memory.availableValue?.text ?? "–"
        if let network {
            networkText = "↓\(ByteFormatting.compact(bytesPerSecond: network.receivedPerSecond)) ↑\(ByteFormatting.compact(bytesPerSecond: network.sentPerSecond))"
        } else {
            networkText = "↓– ↑–"
        }

        var parts = ["MacFleet."]
        parts.append(cpu.availableValue.map { "CPU \($0.spokenText)." } ?? "CPU unavailable.")
        parts.append(memory.availableValue.map { "Memory \($0.spokenText)." } ?? "Memory unavailable.")
        if let network {
            parts.append("Download \(SpokenFormatting.rate(network.receivedPerSecond)), upload \(SpokenFormatting.rate(network.sentPerSecond)).")
        } else {
            parts.append("Network unavailable.")
        }
        accessibilityLabel = parts.joined(separator: " ")
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
        menuBar = MenuBarPresentation(
            cpu: cpu.total,
            memory: memory.usage,
            network: AggregateNetworkRate.rate(snapshot.network)
        )
    }
}
