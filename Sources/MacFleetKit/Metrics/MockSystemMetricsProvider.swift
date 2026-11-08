import Foundation

public struct MockSystemMetricsProvider: SystemMetricsProviding {
    public static let sampleSnapshot = SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostName: "sample-mac.local",
        operatingSystemVersion: "Version 15.0 (Build 24A0)",
        activeProcessorCount: 8,
        physicalMemoryBytes: 17_179_869_184,
        uptimeSeconds: 3_600,
        loadAverage: LoadAverage(oneMinute: 1.5, fiveMinutes: 1.2, fifteenMinutes: 0.9),
        cpu: .available(CPUUtilization(
            total: 0.25,
            perCore: .available([0.10, 0.40, 0.20, 0.30, 0.15, 0.35, 0.22, 0.28])
        )),
        memory: .available(MemoryUsage(
            totalBytes: 17_179_869_184,
            usedBytes: 8_589_934_592,
            availableBytes: 8_589_934_592
        )),
        memoryPressure: .available(.normal),
        volumes: .available([
            VolumeMetrics(
                name: "Macintosh HD",
                mountPoint: "/",
                isRemovable: false,
                isBrowsable: true,
                capacity: .available(DiskCapacity(totalBytes: 500_000_000_000, availableBytes: 200_000_000_000))
            ),
        ]),
        network: .available([
            NetworkInterfaceMetrics(
                name: "en0",
                isUp: true,
                isLoopback: false,
                ipv4Addresses: ["192.168.1.20"],
                totals: .available(NetworkTotals(bytesReceived: 12_000_000_000, bytesSent: 3_000_000_000)),
                rates: .available(NetworkRate(receivedPerSecond: 1_200_000, sentPerSecond: 40_000))
            ),
        ])
    )

    private let result: Result<SystemSnapshot, any Error>

    public init(result: Result<SystemSnapshot, any Error> = .success(Self.sampleSnapshot)) {
        self.result = result
    }

    public func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        try result.get()
    }
}
