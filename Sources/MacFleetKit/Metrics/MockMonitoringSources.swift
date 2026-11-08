/// Scripted volume listings for tests and previews. See `ScriptedReadings` for repeat behavior.
public struct MockVolumeSource: VolumeSource {
    private var script: [Result<[RawVolume], MetricIssue>]

    public init(_ script: [Result<[RawVolume], MetricIssue>] = []) {
        self.script = script
    }

    public mutating func volumes() throws(MetricIssue) -> [RawVolume] {
        try ScriptedReadings.next(&script)
    }
}

/// Scripted interface listings for tests and previews. See `ScriptedReadings` for repeat behavior.
public struct MockInterfaceSource: InterfaceSource {
    private var script: [Result<[RawInterface], MetricIssue>]

    public init(_ script: [Result<[RawInterface], MetricIssue>] = []) {
        self.script = script
    }

    public mutating func interfaces() throws(MetricIssue) -> [RawInterface] {
        try ScriptedReadings.next(&script)
    }
}
