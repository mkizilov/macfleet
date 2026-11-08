import MacFleetKit

/// Fixed-capacity samples, oldest first. A `nil` sample is a gap where the reading was unavailable.
public struct MetricSeries: Equatable, Sendable {
    public let capacity: Int
    public private(set) var samples: [Double?] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ sample: Double?) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}

/// Recent history for the dashboard charts. Memory is bounded by `capacity` per series.
public struct MetricHistory: Equatable, Sendable {
    public private(set) var cpu: MetricSeries
    public private(set) var memory: MetricSeries
    public private(set) var download: MetricSeries
    public private(set) var upload: MetricSeries

    public init(capacity: Int = 120) {
        cpu = MetricSeries(capacity: capacity)
        memory = MetricSeries(capacity: capacity)
        download = MetricSeries(capacity: capacity)
        upload = MetricSeries(capacity: capacity)
    }

    public mutating func record(_ snapshot: SystemSnapshot) {
        cpu.append(snapshot.cpu.availableValue?.total)
        memory.append(MemoryFraction.used(snapshot.memory))
        let rate = AggregateNetworkRate.rate(snapshot.network)
        download.append(rate?.receivedPerSecond)
        upload.append(rate?.sentPerSecond)
    }
}

enum MemoryFraction {
    static func used(_ reading: MetricReading<MemoryUsage>) -> Double? {
        guard let usage = reading.availableValue, usage.totalBytes > 0 else { return nil }
        return Double(usage.usedBytes) / Double(usage.totalBytes)
    }
}

/// Sum of per-interface rates across every monitored interface. Nil when any monitored interface lacks
/// a rate, so a partial sum is never shown as the total.
public enum AggregateNetworkRate {
    public static func rate(_ network: MetricReading<[NetworkInterfaceMetrics]>) -> NetworkRate? {
        guard let interfaces = network.availableValue else { return nil }
        var received = 0.0
        var sent = 0.0
        var monitored = 0
        for interface in interfaces {
            switch interface.rates {
            case let .available(rate):
                received += rate.receivedPerSecond
                sent += rate.sentPerSecond
                monitored += 1
            case .unavailable(.notMonitored):
                continue
            case .unavailable:
                return nil
            }
        }
        guard monitored > 0 else { return nil }
        return NetworkRate(receivedPerSecond: received, sentPerSecond: sent)
    }
}
