import Foundation

public struct LoadAverage: Codable, Equatable, Sendable {
    public let oneMinute: Double
    public let fiveMinutes: Double
    public let fifteenMinutes: Double

    public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
        self.oneMinute = oneMinute
        self.fiveMinutes = fiveMinutes
        self.fifteenMinutes = fifteenMinutes
    }
}

public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let hostName: String
    public let operatingSystemVersion: String
    public let activeProcessorCount: Int
    public let physicalMemoryBytes: UInt64
    public let uptimeSeconds: TimeInterval
    public let loadAverage: LoadAverage

    public init(
        capturedAt: Date,
        hostName: String,
        operatingSystemVersion: String,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64,
        uptimeSeconds: TimeInterval,
        loadAverage: LoadAverage
    ) {
        self.capturedAt = capturedAt
        self.hostName = hostName
        self.operatingSystemVersion = operatingSystemVersion
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.uptimeSeconds = uptimeSeconds
        self.loadAverage = loadAverage
    }
}
