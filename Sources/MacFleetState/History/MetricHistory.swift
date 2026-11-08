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
        memory.append(snapshot.memory.availableValue?.usedFraction)
        let rate = AggregateNetworkRate.rate(snapshot.network)
        download.append(rate?.receivedPerSecond)
        upload.append(rate?.sentPerSecond)
    }
}
