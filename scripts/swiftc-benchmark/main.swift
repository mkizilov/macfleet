import Darwin
import Foundation
import MacFleetKit
import MacFleetState

// Times the work done once per sample for the dashboard: appending to the bounded history and
// building the presentation. System reads are excluded; the simulated timeline generates the inputs
// before timing starts, so only dashboard work is measured.

let samples = 2_000
let capacity = 120
var timeline = SimulatedMetricsTimeline(seed: 42)
let start = Date(timeIntervalSince1970: 1_767_225_600)
let snapshots = (0..<samples).map { index in
    timeline.nextSnapshot(
        selection: .default,
        capturedAt: start.addingTimeInterval(Double(index) * SimulatedMetricsTimeline.stepSeconds)
    )
}

var history = MetricHistory(capacity: capacity)
var microseconds: [Double] = []
microseconds.reserveCapacity(samples)
var checksum = 0
for snapshot in snapshots {
    let began = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    history.record(snapshot)
    let dashboard = DashboardPresentation(snapshot: snapshot, history: history, selection: .default)
    let ended = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    microseconds.append(Double(ended - began) / 1_000)
    checksum &+= dashboard.menuBar.cpuText.count &+ dashboard.cpu.history.series.count
}

let sorted = microseconds.sorted()
let median = sorted[sorted.count / 2]
let p95 = sorted[Int(Double(sorted.count) * 0.95)]
let worst = sorted[sorted.count - 1]
let mean = microseconds.reduce(0, +) / Double(microseconds.count)

print("samples: \(samples), history capacity: \(capacity)")
print(String(format: "dashboard work per sample (us): mean %.1f, median %.1f, p95 %.1f, max %.1f", mean, median, p95, worst))
print("history after run: cpu \(history.cpu.samples.count), network \(history.download.samples.count) samples")
print("checksum: \(checksum)")
