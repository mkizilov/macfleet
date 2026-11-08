import Foundation
import MacFleetKit

/// One alert: a metric, and for disks the mount point it watches. Other metrics use an empty subject.
public struct AlertKey: Hashable, Comparable, Sendable {
    public let metric: AlertMetric
    public let subject: String

    public init(metric: AlertMetric, subject: String = "") {
        self.metric = metric
        self.subject = subject
    }

    public static func < (lhs: AlertKey, rhs: AlertKey) -> Bool {
        (lhs.metric.rawValue, lhs.subject) < (rhs.metric.rawValue, rhs.subject)
    }
}

/// An alert that should be announced. The message names the reading that crossed the threshold.
public struct AlertNotice: Equatable, Sendable {
    public let key: AlertKey
    public let title: String
    public let message: String
    public let firedAt: Date

    public init(key: AlertKey, title: String, message: String, firedAt: Date) {
        self.key = key
        self.title = title
        self.message = message
        self.firedAt = firedAt
    }
}

/// What the engine is doing now, for the settings screen. Labels name the alerts that are firing.
public struct AlertStatus: Equatable, Sendable {
    public let firing: [AlertMetric: [String]]
    /// Metrics whose condition is present but has not lasted long enough to fire.
    public let waiting: Set<AlertMetric>

    public static let idle = AlertStatus(firing: [:], waiting: [])

    public init(firing: [AlertMetric: [String]], waiting: Set<AlertMetric>) {
        self.firing = firing
        self.waiting = waiting
    }
}

/// Turns a stream of snapshots into alert notices. It is a pure state machine: each decision depends only on the
/// snapshots and their capture times, so tests drive it with a simulated clock.
///
/// Each alert moves through three phases:
/// - clear: the reading is short of the threshold.
/// - pending: the reading has reached the threshold and must stay there for the sustained period.
/// - active: the alert has fired. It clears only when the reading passes the hysteresis band.
///
/// A notice is owed when an alert becomes active. It is sent once the cooldown since the last notice for that alert
/// has ended. If the alert clears before then, the owed notice is dropped.
public struct AlertEngine: Sendable {
    /// Hysteresis margins. An active alert clears only past these, so a reading that hovers at the threshold cannot
    /// clear and re-fire on every sample.
    static let cpuClearMargin = 5.0
    static let diskClearMargin = 2.0
    static let networkClearFraction = 0.8

    /// A gap this long between two snapshots means the Mac slept. A pending period does not count across it.
    static let maximumSampleGap: TimeInterval = 60

    private enum Phase: Equatable, Sendable {
        case clear
        case pending(since: Date)
        case active
    }

    private struct AlertState: Sendable {
        var label: String
        var phase = Phase.clear
        var notificationOwed = false
        var lastNotified: Date?
    }

    /// One reading of one alert on one snapshot. A nil condition means the reading is unavailable.
    private struct Condition {
        let label: String
        let breaches: Bool
        let clears: Bool
        let summary: String
    }

    private struct Observation {
        let key: AlertKey
        let condition: Condition?
    }

    /// `complete` means the observations cover every alert of the metric, so alerts without an observation (a volume
    /// that was unmounted or unmonitored) are dropped. An incomplete set leaves every alert as it was.
    private struct Observations {
        let items: [Observation]
        let complete: Bool
    }

    public private(set) var settings: AlertSettings
    private var states: [AlertKey: AlertState] = [:]
    private var lastEvaluation: Date?

    public init(settings: AlertSettings = AlertSettings()) {
        self.settings = settings
    }

    public var status: AlertStatus {
        var firing: [AlertMetric: [String]] = [:]
        var waiting: Set<AlertMetric> = []
        for (key, state) in states.sorted(by: { $0.key < $1.key }) {
            switch state.phase {
            case .active:
                firing[key.metric, default: []].append(state.label)
            case .pending:
                waiting.insert(key.metric)
            case .clear:
                break
            }
        }
        return AlertStatus(firing: firing, waiting: waiting)
    }

    /// Applies new settings from the next evaluation on. Disabling a metric forgets its alerts, so re-enabling it
    /// starts clear.
    public mutating func apply(_ settings: AlertSettings) {
        self.settings = settings
        for metric in AlertMetric.allCases where !settings.rule(for: metric).isEnabled {
            states = states.filter { $0.key.metric != metric }
        }
    }

    /// Evaluates one snapshot at its capture time and returns the notices to send, in key order.
    public mutating func evaluate(_ snapshot: SystemSnapshot) -> [AlertNotice] {
        let now = snapshot.capturedAt
        let slept = lastEvaluation.map { now.timeIntervalSince($0) > Self.maximumSampleGap } ?? false
        lastEvaluation = now

        var notices: [AlertNotice] = []
        for metric in AlertMetric.allCases {
            let rule = settings.rule(for: metric)
            guard rule.isEnabled else { continue }
            let observed = Self.observations(for: metric, threshold: rule.threshold, in: snapshot)
            if observed.complete {
                let present = Set(observed.items.map(\.key))
                states = states.filter { $0.key.metric != metric || present.contains($0.key) }
            }
            for item in observed.items {
                var state = states[item.key] ?? AlertState(label: metric.title)
                if let label = item.condition?.label {
                    state.label = label
                }
                if let notice = Self.advance(&state, item.condition, rule, item.key, now, slept) {
                    notices.append(notice)
                }
                states[item.key] = state
            }
        }
        return notices.sorted { $0.key < $1.key }
    }

    private static func advance(
        _ state: inout AlertState,
        _ condition: Condition?,
        _ rule: AlertRule,
        _ key: AlertKey,
        _ now: Date,
        _ slept: Bool
    ) -> AlertNotice? {
        guard let condition else {
            // Unavailable readings never clear an active alert. They do break a pending period, because the
            // condition was not observed through the gap.
            if case .pending = state.phase {
                state.phase = .clear
            }
            return nil
        }
        if slept, case .pending = state.phase {
            state.phase = .clear
        }

        switch state.phase {
        case .clear:
            guard condition.breaches else { return nil }
            if rule.sustainedSeconds <= 0 {
                return activate(&state, condition, rule, key, now)
            }
            state.phase = .pending(since: now)
            return nil
        case let .pending(since):
            guard condition.breaches else {
                state.phase = .clear
                return nil
            }
            guard now.timeIntervalSince(since) >= rule.sustainedSeconds else { return nil }
            return activate(&state, condition, rule, key, now)
        case .active:
            if condition.clears {
                state.phase = .clear
                state.notificationOwed = false
                return nil
            }
            return owedNotice(&state, condition, rule, key, now)
        }
    }

    private static func activate(
        _ state: inout AlertState,
        _ condition: Condition,
        _ rule: AlertRule,
        _ key: AlertKey,
        _ now: Date
    ) -> AlertNotice? {
        state.phase = .active
        state.notificationOwed = true
        return owedNotice(&state, condition, rule, key, now)
    }

    /// Sends the owed notice once the cooldown since the last notice has ended.
    private static func owedNotice(
        _ state: inout AlertState,
        _ condition: Condition,
        _ rule: AlertRule,
        _ key: AlertKey,
        _ now: Date
    ) -> AlertNotice? {
        guard state.notificationOwed else { return nil }
        if let last = state.lastNotified, now.timeIntervalSince(last) < rule.cooldownSeconds {
            return nil
        }
        state.notificationOwed = false
        state.lastNotified = now
        return AlertNotice(key: key, title: key.metric.title, message: condition.summary, firedAt: now)
    }

    private static func observations(
        for metric: AlertMetric,
        threshold: Double,
        in snapshot: SystemSnapshot
    ) -> Observations {
        switch metric {
        case .highCPU:
            let condition = snapshot.cpu.availableValue.map { cpu -> Condition in
                let percent = cpu.total * 100
                return Condition(
                    label: metric.title,
                    breaches: percent >= threshold,
                    clears: percent < threshold - cpuClearMargin,
                    summary: "CPU is at \(AlertFormat.percent(percent)), at or above the \(AlertFormat.percent(threshold)) threshold."
                )
            }
            return single(metric, condition)
        case .memoryPressure:
            let level = snapshot.memoryPressure.availableValue.map(memoryLevel)
            return single(metric, ordinalCondition(metric, level, threshold))
        case .thermalPressure:
            let level = snapshot.hardware.availableValue?.thermalState.availableValue.map(thermalLevel)
            return single(metric, ordinalCondition(metric, level, threshold))
        case .highNetwork:
            let condition = AggregateNetworkRate.rate(snapshot.network).map { rate -> Condition in
                let megabytes = (rate.receivedPerSecond + rate.sentPerSecond) / 1_000_000
                return Condition(
                    label: metric.title,
                    breaches: megabytes >= threshold,
                    clears: megabytes < threshold * networkClearFraction,
                    summary: "Download and upload total \(AlertFormat.megabytesPerSecond(megabytes)), at or above \(AlertFormat.megabytesPerSecond(threshold))."
                )
            }
            return single(metric, condition)
        case .lowDiskSpace:
            guard case let .available(volumes) = snapshot.volumes else {
                return Observations(items: [], complete: false)
            }
            var items: [Observation] = []
            for volume in volumes where volume.isBrowsable {
                if case .unavailable(.notMonitored) = volume.capacity {
                    continue
                }
                let condition = volume.capacity.availableValue.flatMap { capacity -> Condition? in
                    guard capacity.totalBytes > 0 else { return nil }
                    let free = Double(capacity.availableBytes) / Double(capacity.totalBytes) * 100
                    return Condition(
                        label: volume.name,
                        breaches: free <= threshold,
                        clears: free > threshold + diskClearMargin,
                        summary: "\(volume.name) has \(AlertFormat.percent(free)) free, at or below the \(AlertFormat.percent(threshold)) threshold."
                    )
                }
                items.append(Observation(key: AlertKey(metric: metric, subject: volume.mountPoint), condition: condition))
            }
            return Observations(items: items, complete: true)
        }
    }

    private static func single(_ metric: AlertMetric, _ condition: Condition?) -> Observations {
        Observations(items: [Observation(key: AlertKey(metric: metric), condition: condition)], complete: true)
    }

    /// Ordinal levels are discrete, so the band is the level itself: a level below the threshold clears the alert.
    private static func ordinalCondition(_ metric: AlertMetric, _ level: Int?, _ threshold: Double) -> Condition? {
        guard let level else { return nil }
        return Condition(
            label: metric.title,
            breaches: Double(level) >= threshold,
            clears: Double(level) < threshold,
            summary: "\(metric.title) is \(metric.levelNames[level])."
        )
    }

    private static func memoryLevel(_ level: MemoryPressureLevel) -> Int {
        switch level {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    private static func thermalLevel(_ state: ThermalState) -> Int {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}
