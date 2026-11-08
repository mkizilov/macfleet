import Foundation
import MacFleetKit

/// Runs `body` in a project-local scratch directory, under `.agent-local/tmp`, and removes it afterwards.
/// Removal is best effort: a leftover directory is harmless and is cleaned by the next run's owner.
func withScratchDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let root = repository.appendingPathComponent(".agent-local/tmp/history-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// A snapshot with the given readings. Memory, disk, and rates are chosen so the expected values are exact.
func makeSnapshot(
    at time: TimeInterval,
    cpu: Double = 0.2,
    memory: Double = 0.5,
    download: Double = 1_000,
    upload: Double = 100,
    disk: Double = 0.6,
    cpuReading: MetricReading<CPUUtilization>? = nil,
    network: MetricReading<[NetworkInterfaceMetrics]>? = nil
) -> SystemSnapshot {
    let total: UInt64 = 10_000
    let used = UInt64((memory * Double(total)).rounded())
    let capacity: UInt64 = 1_000_000
    let free = UInt64(((1 - disk) * Double(capacity)).rounded())
    let defaultNetwork: MetricReading<[NetworkInterfaceMetrics]> = .available([
        NetworkInterfaceMetrics(
            name: "en0",
            isUp: true,
            isLoopback: false,
            ipv4Addresses: ["192.168.1.2"],
            totals: .available(NetworkTotals(bytesReceived: 0, bytesSent: 0)),
            rates: .available(NetworkRate(receivedPerSecond: download, sentPerSecond: upload))
        ),
    ])
    return SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: time),
        hostName: "test-mac",
        operatingSystemVersion: "Test OS",
        activeProcessorCount: 4,
        physicalMemoryBytes: total,
        uptimeSeconds: 100,
        loadAverage: LoadAverage(oneMinute: 1, fiveMinutes: 1, fifteenMinutes: 1),
        cpu: cpuReading ?? .available(CPUUtilization(total: cpu, perCore: .unavailable(.notSampled))),
        memory: .available(MemoryUsage(totalBytes: total, usedBytes: used, availableBytes: total - used)),
        memoryPressure: .available(.normal),
        volumes: .available([
            VolumeMetrics(
                name: "Macintosh HD",
                mountPoint: "/",
                isRemovable: false,
                isBrowsable: true,
                capacity: .available(DiskCapacity(totalBytes: capacity, availableBytes: free))
            ),
            VolumeMetrics(
                name: "VM",
                mountPoint: "/System/Volumes/VM",
                isRemovable: false,
                isBrowsable: false,
                capacity: .available(DiskCapacity(totalBytes: capacity, availableBytes: capacity))
            ),
        ]),
        network: network ?? defaultNetwork
    )
}

/// Deterministic values in [0, 1) that do not repeat in any short run.
func fraction(_ index: Int, salt: Int) -> Double {
    (Double(index * salt) * 0.618_033_988_7).truncatingRemainder(dividingBy: 1)
}

func variedSnapshot(_ index: Int, origin: TimeInterval, spacing: TimeInterval = 10) -> SystemSnapshot {
    makeSnapshot(
        at: origin + Double(index) * spacing,
        cpu: fraction(index, salt: 1),
        memory: fraction(index, salt: 7),
        download: fraction(index, salt: 3) * 5_000_000,
        upload: fraction(index, salt: 11) * 500_000,
        disk: 0.5 + fraction(index, salt: 5) * 0.2
    )
}

/// Equal within floating-point summation error. Rollups add values in a different order than the test does.
func closeEnough(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) <= 1e-9 * max(1, abs(a), abs(b))
}

func sameAggregate(_ a: MetricAggregate, _ b: MetricAggregate) -> Bool {
    guard a.count == b.count, closeEnough(a.sum, b.sum) else { return false }
    switch (a.maximum, b.maximum) {
    case (nil, nil):
        return true
    case let (.some(x), .some(y)):
        return closeEnough(x, y)
    default:
        return false
    }
}

func sameHistoryPoint(_ a: HistoryPoint, _ b: HistoryPoint) -> Bool {
    guard a.start == b.start, a.samples == b.samples, Set(a.volumes.keys) == Set(b.volumes.keys) else { return false }
    let metrics = [(a.cpu, b.cpu), (a.memory, b.memory), (a.download, b.download), (a.upload, b.upload)]
    guard metrics.allSatisfy({ sameAggregate($0.0, $0.1) }) else { return false }
    return a.volumes.allSatisfy { mount, aggregate in sameAggregate(aggregate, b.volumes[mount] ?? MetricAggregate()) }
}
