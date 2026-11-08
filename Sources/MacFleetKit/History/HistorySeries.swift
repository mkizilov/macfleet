import Foundation

/// A chart-ready history: one value per slot, `nil` where the slot holds no data.
public struct HistorySeries: Equatable, Sendable {
    public struct Volume: Equatable, Sendable {
        public let mountPoint: String
        public let utilization: [Double?]

        public init(mountPoint: String, utilization: [Double?]) {
            self.mountPoint = mountPoint
            self.utilization = utilization
        }
    }

    public let range: HistoryRange
    public let start: Date
    public let end: Date
    public let cpu: [Double?]
    public let memory: [Double?]
    public let download: [Double?]
    public let upload: [Double?]
    public let volumes: [Volume]
    /// Snapshots represented in the window.
    public let samples: Int

    /// The window for `range` ending after `now`. Slot boundaries sit on the epoch grid, so each bucket of the
    /// storing tier falls in exactly one slot, and the newest slot is the one in progress.
    public static func window(range: HistoryRange, now: Date) -> (start: TimeInterval, end: TimeInterval) {
        let width = range.slotWidth
        let end = (floor(now.timeIntervalSince1970 / width) + 1) * width
        return (end - Double(range.slotCount) * width, end)
    }

    public static func build(
        range: HistoryRange,
        start: TimeInterval,
        end: TimeInterval,
        points: [HistoryPoint]
    ) -> HistorySeries {
        let width = range.slotWidth
        var slots = (0..<range.slotCount).map { HistoryPoint(start: start + Double($0) * width) }
        for point in points {
            let index = Int(((point.start - start) / width).rounded(.down))
            guard slots.indices.contains(index) else { continue }
            slots[index].merge(point)
        }
        let mountPoints = Set(slots.flatMap { $0.volumes.keys }).sorted()
        return HistorySeries(
            range: range,
            start: Date(timeIntervalSince1970: start),
            end: Date(timeIntervalSince1970: end),
            cpu: slots.map { $0.cpu.mean },
            memory: slots.map { $0.memory.mean },
            download: slots.map { $0.download.mean },
            upload: slots.map { $0.upload.mean },
            volumes: mountPoints.map { mountPoint in
                Volume(mountPoint: mountPoint, utilization: slots.map { $0.volumes[mountPoint]?.mean })
            },
            samples: slots.reduce(0) { $0 + $1.samples }
        )
    }
}
