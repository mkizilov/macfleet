import Foundation
import MacFleetKit
import MacFleetState
import Testing

private func interface(
    _ name: String,
    rates: MetricReading<NetworkRate>,
    totals: MetricReading<NetworkTotals> = .available(NetworkTotals(bytesReceived: 1, bytesSent: 1))
) -> NetworkInterfaceMetrics {
    NetworkInterfaceMetrics(
        name: name,
        isUp: true,
        isLoopback: false,
        ipv4Addresses: ["192.168.1.2"],
        totals: totals,
        rates: rates
    )
}

private func snapshot(
    cpu: MetricReading<CPUUtilization> = .available(CPUUtilization(total: 0.3, perCore: .available([0.3]))),
    network: MetricReading<[NetworkInterfaceMetrics]> = .available([])
) -> SystemSnapshot {
    SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostName: "test-mac",
        operatingSystemVersion: "Test OS",
        activeProcessorCount: 1,
        physicalMemoryBytes: 1_000,
        uptimeSeconds: 60,
        loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0),
        cpu: cpu,
        memory: .available(MemoryUsage(totalBytes: 1_000, usedBytes: 250, availableBytes: 750)),
        memoryPressure: .available(.normal),
        volumes: .available([]),
        network: network
    )
}

@Suite("Metric series")
struct MetricSeriesTests {
    @Test func keepsOnlyTheMostRecentSamples() {
        var series = MetricSeries(capacity: 10)
        for index in 0..<500 {
            series.append(Double(index))
        }
        #expect(series.samples.count == 10)
        #expect(series.samples.first == 490)
        #expect(series.samples.last == 499)
    }

    @Test func gapsAreStoredAsNilNotZero() {
        var series = MetricSeries(capacity: 4)
        series.append(0.5)
        series.append(nil)
        series.append(0.7)
        #expect(series.samples == [0.5, nil, 0.7])
    }

    @Test func zeroCapacityStillHoldsOneSample() {
        var series = MetricSeries(capacity: 0)
        series.append(1)
        series.append(2)
        #expect(series.samples == [2])
    }
}

@Suite("Metric history")
struct MetricHistoryTests {
    @Test func recordsCPUAndMemoryFractions() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot())
        #expect(history.cpu.samples == [0.3])
        #expect(history.memory.samples == [0.25])
    }

    @Test func unavailableCPUBecomesAGap() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot(cpu: .unavailable(.noElapsedTicks)))
        #expect(history.cpu.samples == [nil])
    }

    @Test func networkSumIncludesEveryMonitoredInterface() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot(network: .available([
            interface("en0", rates: .available(NetworkRate(receivedPerSecond: 100, sentPerSecond: 10))),
            interface("utun3", rates: .available(NetworkRate(receivedPerSecond: 50, sentPerSecond: 5))),
            interface("lo0", rates: .unavailable(.notMonitored)),
        ])))
        #expect(history.download.samples == [150])
        #expect(history.upload.samples == [15])
    }

    @Test func partialNetworkSumIsAGapNotAnUnderstatedTotal() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot(network: .available([
            interface("en0", rates: .available(NetworkRate(receivedPerSecond: 100, sentPerSecond: 10))),
            interface("utun3", rates: .unavailable(.counterReset)),
        ])))
        #expect(history.download.samples == [nil])
        #expect(history.upload.samples == [nil])
    }

    @Test func allInterfacesExcludedIsAGap() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot(network: .available([
            interface("lo0", rates: .unavailable(.notMonitored)),
        ])))
        #expect(history.download.samples == [nil])
    }

    @Test func unavailableNetworkListIsAGap() {
        var history = MetricHistory(capacity: 5)
        history.record(snapshot(network: .unavailable(.kernelCallFailed(call: "getifaddrs", code: 1))))
        #expect(history.download.samples == [nil])
    }

    @Test func historyIsBoundedAcrossManyRecords() {
        var history = MetricHistory(capacity: 120)
        for _ in 0..<1_000 {
            history.record(snapshot())
        }
        #expect(history.cpu.samples.count == 120)
        #expect(history.memory.samples.count == 120)
        #expect(history.download.samples.count == 120)
    }
}
