import Foundation

/// Cumulative byte counters for one interface.
public struct NetworkTotals: Codable, Equatable, Sendable {
    public let bytesReceived: UInt64
    public let bytesSent: UInt64

    public init(bytesReceived: UInt64, bytesSent: UInt64) {
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
    }
}

public struct NetworkRate: Codable, Equatable, Sendable {
    public let receivedPerSecond: Double
    public let sentPerSecond: Double

    public init(receivedPerSecond: Double, sentPerSecond: Double) {
        self.receivedPerSecond = receivedPerSecond
        self.sentPerSecond = sentPerSecond
    }
}

/// An interface as the operating system reports it. `totals` carries its own failure.
public struct RawInterface: Equatable, Sendable {
    public let name: String
    public let isUp: Bool
    public let isLoopback: Bool
    public let ipv4Addresses: [String]
    public let totals: MetricReading<NetworkTotals>

    public init(name: String, isUp: Bool, isLoopback: Bool, ipv4Addresses: [String], totals: MetricReading<NetworkTotals>) {
        self.name = name
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.ipv4Addresses = ipv4Addresses
        self.totals = totals
    }
}

public protocol InterfaceSource: Sendable {
    mutating func interfaces() throws(MetricIssue) -> [RawInterface]
}

public struct NetworkInterfaceMetrics: Codable, Equatable, Sendable {
    public let name: String
    public let isUp: Bool
    public let isLoopback: Bool
    public let ipv4Addresses: [String]
    public let totals: MetricReading<NetworkTotals>
    public let rates: MetricReading<NetworkRate>

    public init(
        name: String,
        isUp: Bool,
        isLoopback: Bool,
        ipv4Addresses: [String],
        totals: MetricReading<NetworkTotals>,
        rates: MetricReading<NetworkRate>
    ) {
        self.name = name
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.ipv4Addresses = ipv4Addresses
        self.totals = totals
        self.rates = rates
    }
}

enum NetworkRateCalculator {
    static func rate(previous: NetworkTotals, current: NetworkTotals, elapsed: TimeInterval) throws(MetricIssue) -> NetworkRate {
        guard elapsed > 0 else { throw .noElapsedTime }
        guard current.bytesReceived >= previous.bytesReceived, current.bytesSent >= previous.bytesSent else {
            throw .counterReset
        }
        return NetworkRate(
            receivedPerSecond: Double(current.bytesReceived - previous.bytesReceived) / elapsed,
            sentPerSecond: Double(current.bytesSent - previous.bytesSent) / elapsed
        )
    }
}

/// Derives per-interface rates from the totals recorded at the previous accepted sample. An interface
/// missing from a sample drops out of tracking, so when it returns it starts over with `.notSampled`.
struct NetworkRateTracker: Sendable {
    private struct Baseline: Sendable {
        let timestamp: TimeInterval
        let totals: [String: NetworkTotals]
    }

    private let minimumWindow: TimeInterval
    private var baseline: Baseline?
    private var lastRates: [String: MetricReading<NetworkRate>] = [:]

    init(minimumWindow: TimeInterval) {
        self.minimumWindow = minimumWindow
    }

    mutating func record(
        at timestamp: TimeInterval,
        totals: [String: MetricReading<NetworkTotals>]
    ) -> [String: MetricReading<NetworkRate>] {
        guard let previous = baseline else {
            baseline = Baseline(timestamp: timestamp, totals: Self.available(totals))
            lastRates = Self.rates(for: totals, previous: [:], elapsed: 0)
            return lastRates
        }
        let elapsed = timestamp - previous.timestamp
        guard elapsed >= minimumWindow else {
            return totals.reduce(into: [:]) { result, entry in
                if case let .unavailable(issue) = entry.value {
                    result[entry.key] = .unavailable(issue)
                } else {
                    result[entry.key] = lastRates[entry.key] ?? .unavailable(.notSampled)
                }
            }
        }
        baseline = Baseline(timestamp: timestamp, totals: Self.available(totals))
        lastRates = Self.rates(for: totals, previous: previous.totals, elapsed: elapsed)
        return lastRates
    }

    private static func available(_ totals: [String: MetricReading<NetworkTotals>]) -> [String: NetworkTotals] {
        totals.compactMapValues { $0.availableValue }
    }

    private static func rates(
        for totals: [String: MetricReading<NetworkTotals>],
        previous: [String: NetworkTotals],
        elapsed: TimeInterval
    ) -> [String: MetricReading<NetworkRate>] {
        totals.reduce(into: [:]) { result, entry in
            result[entry.key] = rate(for: entry.value, previous: previous[entry.key], elapsed: elapsed)
        }
    }

    private static func rate(
        for total: MetricReading<NetworkTotals>,
        previous: NetworkTotals?,
        elapsed: TimeInterval
    ) -> MetricReading<NetworkRate> {
        switch total {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(current):
            guard let previous else { return .unavailable(.notSampled) }
            do throws(MetricIssue) {
                return .available(try NetworkRateCalculator.rate(previous: previous, current: current, elapsed: elapsed))
            } catch {
                return .unavailable(error)
            }
        }
    }
}
