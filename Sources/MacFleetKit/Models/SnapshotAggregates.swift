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

extension MemoryUsage {
    /// Used memory as a share of total, or nil when the total is zero.
    public var usedFraction: Double? {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : nil
    }
}
