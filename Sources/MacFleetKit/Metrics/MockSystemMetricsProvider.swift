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
        memoryPressure: .available(.normal)
    )

    private let result: Result<SystemSnapshot, any Error>

    public init(result: Result<SystemSnapshot, any Error> = .success(Self.sampleSnapshot)) {
        self.result = result
    }

    public func snapshot() async throws -> SystemSnapshot {
        try result.get()
    }
}
