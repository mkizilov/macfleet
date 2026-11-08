import Foundation

public struct ProcessSystemMetricsProvider: SystemMetricsProviding {
    public init() {}

    public func snapshot() async throws -> SystemSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else {
            throw MetricsError.loadAverageUnavailable
        }
        let info = ProcessInfo.processInfo
        return SystemSnapshot(
            capturedAt: Date(),
            hostName: info.hostName,
            operatingSystemVersion: info.operatingSystemVersionString,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            uptimeSeconds: info.systemUptime,
            loadAverage: LoadAverage(
                oneMinute: loads[0],
                fiveMinutes: loads[1],
                fifteenMinutes: loads[2]
            )
        )
    }
}
