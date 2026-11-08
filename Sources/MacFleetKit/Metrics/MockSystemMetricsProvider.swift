import Foundation

public struct MockSystemMetricsProvider: SystemMetricsProviding {
    public static let sampleSnapshot = SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostName: "sample-mac.local",
        operatingSystemVersion: "Version 15.0 (Build 24A0)",
        activeProcessorCount: 8,
        physicalMemoryBytes: 17_179_869_184,
        uptimeSeconds: 3_600,
        loadAverage: LoadAverage(oneMinute: 1.5, fiveMinutes: 1.2, fifteenMinutes: 0.9)
    )

    private let result: Result<SystemSnapshot, any Error>

    public init(result: Result<SystemSnapshot, any Error> = .success(Self.sampleSnapshot)) {
        self.result = result
    }

    public func snapshot() async throws -> SystemSnapshot {
        try result.get()
    }
}
