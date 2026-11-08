import AppKit
import MacFleetKit
import MacFleetState
import SwiftUI

public struct StatusPopoverView: View {
    private let model: FleetStatusModel

    public init(model: FleetStatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacFleet")
                .font(.headline)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SystemSummaryView(snapshot: snapshot)
                        DiskSection(volumes: snapshot.volumes)
                        NetworkSection(interfaces: snapshot.network)
                        SourcesSection(
                            model: model,
                            volumes: snapshot.volumes.availableValue ?? [],
                            interfaces: snapshot.network.availableValue ?? []
                        )
                    }
                }
                .frame(maxHeight: 420)
            } else {
                Text("No system data yet.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .task { await model.refresh() }
    }
}

private struct SystemSummaryView: View {
    let snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Host", value: snapshot.hostName)
            LabeledContent("OS", value: snapshot.operatingSystemVersion)
            LabeledContent("CPUs", value: "\(snapshot.activeProcessorCount)")
            LabeledContent("CPU", value: snapshot.cpu.text { percent($0.total) })
            LabeledContent("Cores", value: snapshot.cpu.text { cpu in cpu.perCore.text { cores in
                cores.map { percent($0) }.joined(separator: " ")
            } })
            LabeledContent("Memory", value: snapshot.memory.text { memory in
                "\(bytes(memory.usedBytes)) used of \(bytes(memory.totalBytes))"
            })
            LabeledContent("Available", value: snapshot.memory.text { bytes($0.availableBytes) })
            LabeledContent("Pressure", value: snapshot.memoryPressure.text { $0.title })
            LabeledContent(
                "Uptime",
                value: Duration.seconds(snapshot.uptimeSeconds)
                    .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
            )
            LabeledContent(
                "Load (1m)",
                value: snapshot.loadAverage.oneMinute.formatted(.number.precision(.fractionLength(2)))
            )
        }
        .font(.callout)
    }
}

private struct DiskSection: View {
    let volumes: MetricReading<[VolumeMetrics]>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disks")
                .font(.subheadline.bold())
            if let failure = volumes.failureText {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(volumes.availableValue?.filter { $0.isShownInSummary } ?? [], id: \.mountPoint) { volume in
                VStack(alignment: .leading, spacing: 1) {
                    LabeledContent(
                        volume.isRemovable ? "\(volume.name) (removable)" : volume.name,
                        value: volume.capacity.text { "\(percent($0.utilization)) used" }
                    )
                    Text(volume.capacity.text { capacity in
                        "\(ByteFormatting.string(bytes: capacity.availableBytes)) free of \(ByteFormatting.string(bytes: capacity.totalBytes))"
                    })
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

private struct NetworkSection: View {
    let interfaces: MetricReading<[NetworkInterfaceMetrics]>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network")
                .font(.subheadline.bold())
            if let failure = interfaces.failureText {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(interfaces.availableValue?.filter { $0.isShownInSummary } ?? [], id: \.name) { interface in
                VStack(alignment: .leading, spacing: 1) {
                    LabeledContent(
                        interface.isUp ? interface.name : "\(interface.name) (down)",
                        value: interface.rates.text { rate in
                            "↓ \(ByteFormatting.rate(bytesPerSecond: rate.receivedPerSecond))  ↑ \(ByteFormatting.rate(bytesPerSecond: rate.sentPerSecond))"
                        }
                    )
                    Text(interface.totals.text { totals in
                        "Received \(ByteFormatting.string(bytes: totals.bytesReceived)) · Sent \(ByteFormatting.string(bytes: totals.bytesSent))"
                    })
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

private struct SourcesSection: View {
    let model: FleetStatusModel
    let volumes: [VolumeMetrics]
    let interfaces: [NetworkInterfaceMetrics]

    var body: some View {
        DisclosureGroup("Monitored sources") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(volumes, id: \.mountPoint) { volume in
                    Toggle(isOn: volumeBinding(volume.mountPoint)) {
                        Text("\(volume.name) (\(volume.mountPoint))")
                    }
                }
                ForEach(interfaces, id: \.name) { interface in
                    Toggle(isOn: interfaceBinding(interface.name)) {
                        Text(interface.name)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private func volumeBinding(_ mountPoint: String) -> Binding<Bool> {
        Binding(
            get: { model.selection.monitorsVolume(at: mountPoint) },
            set: { monitored in Task { await model.setVolumeMonitored(mountPoint, monitored) } }
        )
    }

    private func interfaceBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { model.selection.monitorsInterface(named: name) },
            set: { monitored in Task { await model.setInterfaceMonitored(name, monitored) } }
        )
    }
}

extension MetricReading {
    fileprivate func text(_ format: (Value) -> String) -> String {
        switch self {
        case let .available(value):
            format(value)
        case let .unavailable(issue):
            issue.errorDescription ?? "Unavailable"
        }
    }

    fileprivate var failureText: String? {
        if case let .unavailable(issue) = self {
            issue.errorDescription ?? "Unavailable"
        } else {
            nil
        }
    }
}

extension MemoryPressureLevel {
    fileprivate var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

extension VolumeMetrics {
    /// Browsable volumes are shown in the summary. Hidden system volumes stay in the sources list.
    fileprivate var isShownInSummary: Bool {
        isBrowsable && isMonitored
    }

    fileprivate var isMonitored: Bool {
        if case .unavailable(.notMonitored) = capacity { false } else { true }
    }
}

extension NetworkInterfaceMetrics {
    fileprivate var isMonitored: Bool {
        if case .unavailable(.notMonitored) = totals { false } else { true }
    }

    /// Idle virtual interfaces with no address and no traffic stay out of the summary; they remain in the sources list.
    fileprivate var isShownInSummary: Bool {
        let hasTraffic = (totals.availableValue.map { $0.bytesReceived + $0.bytesSent } ?? 0) > 0
        return isMonitored && (!ipv4Addresses.isEmpty || hasTraffic)
    }
}

private func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}

private func bytes(_ value: UInt64) -> String {
    Int64(value).formatted(.byteCount(style: .memory))
}
