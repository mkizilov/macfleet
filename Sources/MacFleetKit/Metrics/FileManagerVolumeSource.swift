import Foundation

/// Lists mounted volumes with `FileManager` resource values. Reading them needs no special permission,
/// but a volume can still refuse or disappear, so each failure is reported on that volume.
public struct FileManagerVolumeSource: VolumeSource {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsRemovableKey,
        .volumeIsBrowsableKey,
    ]

    public init() {}

    public func volumes() throws(MetricIssue) -> [RawVolume] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) else {
            throw .notProvided(resource: "mounted volume list")
        }
        return urls.map(Self.volume(at:))
    }

    static func volume(at url: URL) -> RawVolume {
        do {
            let values = try url.resourceValues(forKeys: Set(keys))
            return RawVolume(
                name: values.volumeName ?? url.lastPathComponent,
                mountPoint: url.path,
                isRemovable: values.volumeIsRemovable ?? false,
                isBrowsable: values.volumeIsBrowsable ?? true,
                totalBytes: bytes(values.volumeTotalCapacity, resource: "total capacity"),
                availableBytes: bytes(values.volumeAvailableCapacityForImportantUsage, resource: "available capacity")
            )
        } catch {
            let failure = MetricReading<UInt64>.unavailable(issue(for: error, resource: "volume attributes"))
            return RawVolume(
                name: url.lastPathComponent,
                mountPoint: url.path,
                isRemovable: false,
                isBrowsable: true,
                totalBytes: failure,
                availableBytes: failure
            )
        }
    }

    static func issue(for error: Error, resource: String) -> MetricIssue {
        let code = (error as NSError).code
        guard let cocoa = error as? CocoaError else {
            return .readFailed(resource: resource, code: code)
        }
        switch cocoa.code {
        case .fileReadNoPermission:
            return .permissionDenied(resource: resource)
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .volumeDisconnected
        default:
            return .readFailed(resource: resource, code: code)
        }
    }

    private static func bytes<Count: BinaryInteger>(_ value: Count?, resource: String) -> MetricReading<UInt64> {
        guard let value else { return .unavailable(.notProvided(resource: resource)) }
        guard let bytes = UInt64(exactly: value) else { return .unavailable(.inconsistentStorageCounters) }
        return .available(bytes)
    }
}
