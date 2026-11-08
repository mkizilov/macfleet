import MacFleetKit

public struct CoreUsage: Equatable, Sendable, Identifiable {
    public let index: Int
    public let label: String
    public let usage: UsageValue

    public var id: Int { index }
}

public struct CPUPresentation: Equatable, Sendable {
    public let total: Presented<UsageValue>
    public let cores: Presented<[CoreUsage]>
    public let history: ChartPresentation

    init(reading: MetricReading<CPUUtilization>, cpuHistory: MetricSeries) {
        total = presented(reading) { UsageValue(fraction: $0.total) }
        switch reading {
        case let .available(cpu):
            cores = presented(cpu.perCore) { values in
                values.enumerated().map { offset, fraction in
                    CoreUsage(index: offset, label: "Core \(offset + 1)", usage: UsageValue(fraction: fraction))
                }
            }
        case let .unavailable(issue):
            cores = .unavailable(issue.errorDescription ?? "Unavailable")
        }
        history = ChartPresentation(
            title: "CPU history",
            series: [ChartSeries(role: .cpu, name: "CPU", samples: cpuHistory.samples)],
            ceiling: 1,
            spokenSummary: ChartSummary.describe("CPU", samples: cpuHistory.samples, format: SpokenFormatting.percent)
        )
    }
}

public struct PressureBadge: Equatable, Sendable {
    public let title: String
    public let level: UsageLevel
}

public struct MemoryPresentation: Equatable, Sendable {
    public let usage: Presented<UsageValue>
    public let used: Presented<Readout>
    public let available: Presented<Readout>
    public let total: Presented<Readout>
    public let pressure: Presented<PressureBadge>
    public let history: ChartPresentation

    init(reading: MetricReading<MemoryUsage>, pressure: MetricReading<MemoryPressureLevel>, memoryHistory: MetricSeries) {
        usage = Self.usageReading(reading)
        used = presented(reading) { Self.binaryReadout($0.usedBytes) }
        available = presented(reading) { Self.binaryReadout($0.availableBytes) }
        total = presented(reading) { Self.binaryReadout($0.totalBytes) }
        self.pressure = presented(pressure) { Self.badge($0) }
        history = ChartPresentation(
            title: "Memory history",
            series: [ChartSeries(role: .memory, name: "Memory", samples: memoryHistory.samples)],
            ceiling: 1,
            spokenSummary: ChartSummary.describe("Memory", samples: memoryHistory.samples, format: SpokenFormatting.percent)
        )
    }

    private static func usageReading(_ reading: MetricReading<MemoryUsage>) -> Presented<UsageValue> {
        switch reading {
        case let .available(memory):
            guard let fraction = memory.usedFraction else {
                return .unavailable("Total memory is unknown")
            }
            return .available(UsageValue(fraction: fraction))
        case let .unavailable(issue):
            return .unavailable(issue.errorDescription ?? "Unavailable")
        }
    }

    private static func binaryReadout(_ bytes: UInt64) -> Readout {
        Readout(visible: ByteFormatting.binary(bytes: bytes), spoken: SpokenFormatting.bytes(bytes, binary: true))
    }

    private static func badge(_ level: MemoryPressureLevel) -> PressureBadge {
        switch level {
        case .normal: PressureBadge(title: "Normal", level: .normal)
        case .warning: PressureBadge(title: "Warning", level: .elevated)
        case .critical: PressureBadge(title: "Critical", level: .critical)
        }
    }
}

public struct VolumeCapacity: Equatable, Sendable {
    public let usage: UsageValue
    public let free: Readout
}

public struct VolumeRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let badge: String?
    public let capacity: Presented<VolumeCapacity>
}

public struct StoragePresentation: Equatable, Sendable {
    /// Browsable, monitored volumes. Hidden system volumes and excluded volumes appear in the sources list only.
    public let volumes: Presented<[VolumeRow]>
    /// Usage of the first shown volume, for the overview.
    public let primaryUsage: Presented<UsageValue>

    init(reading: MetricReading<[VolumeMetrics]>) {
        let rows: Presented<[VolumeRow]>
        switch reading {
        case let .available(list):
            let shown = list.filter { volume in volume.isBrowsable && volume.isMonitored }
            rows = .available(shown.map(Self.row))
        case let .unavailable(issue):
            rows = .unavailable(issue.errorDescription ?? "Unavailable")
        }
        volumes = rows
        primaryUsage = Self.primaryUsage(rows)
    }

    private static func primaryUsage(_ rows: Presented<[VolumeRow]>) -> Presented<UsageValue> {
        switch rows {
        case let .available(list):
            guard let first = list.first else { return .unavailable("No disks monitored") }
            switch first.capacity {
            case let .available(capacity):
                return .available(capacity.usage)
            case let .unavailable(reason):
                return .unavailable(reason)
            }
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    private static func row(_ volume: VolumeMetrics) -> VolumeRow {
        VolumeRow(
            id: volume.mountPoint,
            name: volume.name,
            badge: volume.isRemovable ? "Removable" : nil,
            capacity: presented(volume.capacity) { capacity in
                VolumeCapacity(
                    usage: UsageValue(fraction: capacity.utilization),
                    free: Readout(
                        visible: "\(ByteFormatting.string(bytes: capacity.availableBytes)) free of \(ByteFormatting.string(bytes: capacity.totalBytes))",
                        spoken: "\(SpokenFormatting.bytes(capacity.availableBytes)) free of \(SpokenFormatting.bytes(capacity.totalBytes))"
                    )
                )
            }
        )
    }
}

public struct InterfaceRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let address: String
    public let download: Presented<Readout>
    public let upload: Presented<Readout>
    public let totals: Presented<Readout>
}

public struct NetworkPresentation: Equatable, Sendable {
    public let download: Presented<Readout>
    public let upload: Presented<Readout>
    public let interfaces: Presented<[InterfaceRow]>
    public let chart: ChartPresentation

    init(reading: MetricReading<[NetworkInterfaceMetrics]>, history: MetricHistory) {
        download = Self.aggregate(reading) { $0.receivedPerSecond }
        upload = Self.aggregate(reading) { $0.sentPerSecond }
        switch reading {
        case let .available(interfaces):
            let shown = interfaces.filter { $0.isMonitored && $0.isShownInSummary }
            self.interfaces = .available(shown.map(Self.row))
        case let .unavailable(issue):
            self.interfaces = .unavailable(issue.errorDescription ?? "Unavailable")
        }
        chart = Self.makeChart(history)
    }

    private static func aggregate(
        _ reading: MetricReading<[NetworkInterfaceMetrics]>,
        _ pick: (NetworkRate) -> Double
    ) -> Presented<Readout> {
        switch reading {
        case .unavailable(let issue):
            return .unavailable(issue.errorDescription ?? "Unavailable")
        case .available:
            guard let rate = AggregateNetworkRate.rate(reading) else {
                return .unavailable("Rate unavailable")
            }
            return .available(rateReadout(pick(rate)))
        }
    }

    private static func row(_ interface: NetworkInterfaceMetrics) -> InterfaceRow {
        let addressText = interface.ipv4Addresses.first ?? "No IPv4 address"
        return InterfaceRow(
            id: interface.name,
            title: interface.isUp ? interface.name : "\(interface.name), down",
            address: addressText,
            download: presented(interface.rates) { rateReadout($0.receivedPerSecond) },
            upload: presented(interface.rates) { rateReadout($0.sentPerSecond) },
            totals: presented(interface.totals) { totals in
                Readout(
                    visible: "Received \(ByteFormatting.string(bytes: totals.bytesReceived)) · Sent \(ByteFormatting.string(bytes: totals.bytesSent))",
                    spoken: "Received \(SpokenFormatting.bytes(totals.bytesReceived)), sent \(SpokenFormatting.bytes(totals.bytesSent))"
                )
            }
        )
    }

    private static func makeChart(_ history: MetricHistory) -> ChartPresentation {
        let download = history.download.samples
        let upload = history.upload.samples
        let peak = (download.compactMap { $0 } + upload.compactMap { $0 }).max() ?? 0
        return ChartPresentation(
            title: "Network history",
            series: [
                ChartSeries(role: .download, name: "Download", samples: download),
                ChartSeries(role: .upload, name: "Upload", samples: upload),
            ],
            ceiling: max(peak * 1.15, 128_000),
            spokenSummary: [
                ChartSummary.describe("Download", samples: download, format: SpokenFormatting.rate),
                ChartSummary.describe("Upload", samples: upload, format: SpokenFormatting.rate),
            ].joined(separator: " ")
        )
    }

    static func rateReadout(_ bytesPerSecond: Double) -> Readout {
        Readout(
            visible: ByteFormatting.rate(bytesPerSecond: bytesPerSecond),
            spoken: SpokenFormatting.rate(bytesPerSecond)
        )
    }
}

/// Plain-language summary of a history series: latest available value and peak.
enum ChartSummary {
    static func describe(_ name: String, samples: [Double?], format: (Double) -> String) -> String {
        let values = samples.compactMap { $0 }
        guard let latest = values.last, let peak = values.max() else {
            return "\(name): no data yet."
        }
        let count = values.count == 1 ? "1 sample" : "\(values.count) samples"
        return "\(name): latest \(format(latest)), peak \(format(peak)) over \(count)."
    }
}

extension NetworkInterfaceMetrics {
    /// Idle virtual interfaces with no address and no traffic stay out of the summary; they remain in the sources list.
    var isShownInSummary: Bool {
        let hasTraffic = (totals.availableValue.map { $0.bytesReceived + $0.bytesSent } ?? 0) > 0
        return !ipv4Addresses.isEmpty || hasTraffic
    }

    var isMonitored: Bool {
        if case .unavailable(.notMonitored) = totals { false } else { true }
    }
}

extension VolumeMetrics {
    var isMonitored: Bool {
        if case .unavailable(.notMonitored) = capacity { false } else { true }
    }
}
