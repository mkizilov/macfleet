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
                SystemSummaryView(snapshot: snapshot)
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

extension MetricReading {
    fileprivate func text(_ format: (Value) -> String) -> String {
        switch self {
        case let .available(value):
            format(value)
        case let .unavailable(issue):
            issue.errorDescription ?? "Unavailable"
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

private func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
}

private func bytes(_ value: UInt64) -> String {
    Int64(value).formatted(.byteCount(style: .memory))
}
