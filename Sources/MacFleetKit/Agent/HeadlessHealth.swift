import Foundation

public enum AgentState: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public enum ListenerState: Codable, Equatable, Sendable {
    /// No address is configured, so the agent accepts no connection. This is the default and is healthy.
    case disabled(reason: String)
    case listening(address: String, port: UInt16)
    case failed(reason: String)
}

/// What the agent reports about itself. It is written to the status file on every change and every sample.
public struct HeadlessHealth: Codable, Equatable, Sendable {
    public var state: AgentState
    public var listener: ListenerState
    public var activeSessions: Int
    public var totalSessions: Int
    public var samplingIntervalSeconds: Double
    public var lastSampleAt: Date?
    public var sampleCount: Int
    public var sampleFailures: Int
    public var lastFailure: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var processID: Int32
    public var version: String

    public init(
        state: AgentState,
        listener: ListenerState,
        activeSessions: Int = 0,
        totalSessions: Int = 0,
        samplingIntervalSeconds: Double,
        lastSampleAt: Date? = nil,
        sampleCount: Int = 0,
        sampleFailures: Int = 0,
        lastFailure: String? = nil,
        startedAt: Date,
        updatedAt: Date,
        processID: Int32,
        version: String
    ) {
        self.state = state
        self.listener = listener
        self.activeSessions = activeSessions
        self.totalSessions = totalSessions
        self.samplingIntervalSeconds = samplingIntervalSeconds
        self.lastSampleAt = lastSampleAt
        self.sampleCount = sampleCount
        self.sampleFailures = sampleFailures
        self.lastFailure = lastFailure
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.processID = processID
        self.version = version
    }
}

public enum HealthVerdict: Equatable, Sendable {
    case healthy
    case unhealthy(reason: String)
}

public enum HeadlessHealthEvaluation {
    /// A sample must be at most this many sampling intervals old, with a floor of 30 seconds, for the agent to count as
    /// sampling.
    public static func maximumSampleAge(samplingIntervalSeconds: Double) -> Double {
        max(30, 3 * samplingIntervalSeconds)
    }

    /// Healthy when the agent is running, its listener is up or deliberately off, its status is fresh, and its last
    /// sample is recent enough.
    public static func verdict(_ health: HeadlessHealth, now: Date) -> HealthVerdict {
        guard health.state == .running else {
            return .unhealthy(reason: "the agent is \(health.state.rawValue)")
        }
        if case let .failed(reason) = health.listener {
            return .unhealthy(reason: "the listener failed: \(reason)")
        }
        let maximumAge = maximumSampleAge(samplingIntervalSeconds: health.samplingIntervalSeconds)
        guard now.timeIntervalSince(health.updatedAt) <= maximumAge else {
            return .unhealthy(reason: "the status file is stale, so the agent may not be running")
        }
        guard let lastSampleAt = health.lastSampleAt else {
            return .unhealthy(reason: "no sample has been taken yet")
        }
        guard now.timeIntervalSince(lastSampleAt) <= maximumAge else {
            return .unhealthy(reason: "the last sample is older than \(Int(maximumAge)) seconds")
        }
        return .healthy
    }
}

/// The health report as a file. Writes are atomic, so a reader never sees half a report.
public enum HeadlessStatusFile {
    public static func write(_ health: HeadlessHealth, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(health)
        try ProtectedFile.write(data, to: path, permissions: 0o644)
    }

    /// Nil when no report exists yet.
    public static func read(from path: String) throws -> HeadlessHealth? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HeadlessHealth.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
