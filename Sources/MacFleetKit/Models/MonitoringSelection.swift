/// Which discovered volumes and network interfaces are measured. Discovery always lists every item;
/// excluded items are reported with `.notMonitored` so they can be turned back on.
public struct MonitoringSelection: Codable, Equatable, Sendable {
    public var excludedVolumePaths: Set<String>
    public var excludedInterfaceNames: Set<String>

    public init(excludedVolumePaths: Set<String> = [], excludedInterfaceNames: Set<String> = []) {
        self.excludedVolumePaths = excludedVolumePaths
        self.excludedInterfaceNames = excludedInterfaceNames
    }

    /// Loopback is excluded by default because its traffic never crosses a network link.
    public static let `default` = MonitoringSelection(excludedInterfaceNames: ["lo0"])

    public static let all = MonitoringSelection()

    public func monitorsVolume(at mountPoint: String) -> Bool {
        !excludedVolumePaths.contains(mountPoint)
    }

    public func monitorsInterface(named name: String) -> Bool {
        !excludedInterfaceNames.contains(name)
    }

    public mutating func setVolume(at mountPoint: String, monitored: Bool) {
        Self.update(&excludedVolumePaths, item: mountPoint, monitored: monitored)
    }

    public mutating func setInterface(named name: String, monitored: Bool) {
        Self.update(&excludedInterfaceNames, item: name, monitored: monitored)
    }

    private static func update(_ excluded: inout Set<String>, item: String, monitored: Bool) {
        if monitored {
            excluded.remove(item)
        } else {
            excluded.insert(item)
        }
    }
}
