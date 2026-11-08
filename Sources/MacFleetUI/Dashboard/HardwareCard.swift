import MacFleetState
import SwiftUI

/// GPU devices, utilization, thermal state, and CPU temperature, each with its status. A measurement this Mac cannot
/// report shows why, in place of a value.
struct HardwareCard: View {
    let hardware: HardwarePresentation

    var body: some View {
        SectionCard("Hardware") {
            VStack(alignment: .leading, spacing: 4) {
                MeasurementHeader(title: "Thermal state", status: hardware.thermalStatus)
                switch hardware.thermal {
                case let .available(display):
                    LevelBadge(title: display.title, level: display.level)
                        .accessibilityLabel(display.spokenText)
                case let .unavailable(reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                MeasurementHeader(title: "CPU temperature", status: hardware.temperatureStatus)
                switch hardware.cpuTemperature {
                case let .available(readout):
                    Text(readout.visible)
                        .font(.callout)
                        .monospacedDigit()
                        .accessibilityLabel(readout.spoken)
                case let .unavailable(reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                MeasurementHeader(title: "GPU utilization", status: hardware.utilizationStatus)
                UsageGauge(title: "GPU utilization", usage: hardware.utilization)
            }
            VStack(alignment: .leading, spacing: 6) {
                MeasurementHeader(title: "GPU devices", status: hardware.devicesStatus)
                devices
            }
            Text("Capabilities")
                .font(.caption.weight(.semibold))
            ForEach(hardware.capabilities) { row in
                CapabilityLine(row: row)
            }
        }
    }

    @ViewBuilder
    private var devices: some View {
        switch hardware.devices {
        case let .available(rows):
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.callout.weight(.medium))
                    Text("\(row.memoryKind) · \(row.capabilities)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.threadgroupLimit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.memory.visible)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(row.memory.spoken)
                }
                .accessibilityElement(children: .combine)
            }
        case let .unavailable(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A measurement's name with its status beside it.
private struct MeasurementHeader: View {
    let title: String
    let status: CapabilityStatus

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            StatusLabel(status: status)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusLabel: View {
    let status: CapabilityStatus

    var body: some View {
        Label(status.title, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch status {
        case .supported: "checkmark.circle"
        case .permissionRestricted: "lock"
        case .unavailable: "minus.circle"
        }
    }
}

private struct CapabilityLine: View {
    let row: CapabilityRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(row.title)
                    .font(.caption)
                Spacer()
                StatusLabel(status: row.status)
            }
            if let reason = row.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
