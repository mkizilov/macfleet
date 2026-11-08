# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. Its menu bar item shows the metrics you choose: CPU, memory, network, and startup disk, or the icon alone. The popover shows an overview, and a details view adds graphs, per-core load, storage, network, and the system summary. The app can also watch other Macs over an authenticated TLS connection, and the headless agent serves this Mac's metrics to them. The `macfleet-agent` command prints the snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`), for building and running the app bundle
- Command Line Tools with a Swift 6 toolchain for the verify, benchmark, and packaging scripts. They use `/Library/Developer/CommandLineTools` by default, and `DEV` or `SDK` override it. CI pins `DEVELOPER_DIR` to that path.

## Layout

| Path | Purpose |
| --- | --- |
| `Package.swift` | Shared Swift package: `MacFleetKit`, `MacFleetState`, `MacFleetUI`, `macfleet-agent`, and tests |
| `Sources/MacFleetKit/Models` | `SystemSnapshot`, `MetricReading` (value or explicit unavailable reason), `MetricIssue`, `MonitoringSelection`, byte and percent formatting |
| `Sources/MacFleetKit/Metrics` | CPU, memory, storage, and network calculations; Mach, FileManager, and getifaddrs/sysctl sources; metric providers; mocks; the simulated timeline |
| `Sources/MacFleetKit/Storage` | Bounded in-memory snapshot store |
| `Sources/MacFleetKit/Processes` | Process listing through libproc, permission-aware readings, CPU windows, and sorting, search, totals, and grouping |
| `Sources/MacFleetKit/Alerts` | Alert metrics, settings and their persistence, notification permission and delivery (`UserNotificationAlertNotifier`), and recording mocks |
| `Sources/MacFleetKit/Remote` | Remote metrics protocol: versioned JSON messages, framing, TLS with a pinned host identity, HMAC client authentication, the network policy, and host and client sessions |
| `Sources/MacFleetKit/Agent` | Headless agent core: configuration, secret stores, structured logging, health reports, local address checks, and the agent lifecycle |
| `Sources/MacFleetState/Remote` | Fleet state: session opening, failure classification, backoff, one watcher per Mac, and the unified overview model |
| `Sources/MacFleetUI/Fleet` | The unified dashboard and the add-a-Mac form |
| `docs/fleet-dashboard.md` | The Fleet window: pairing, trust, retries, storage, and limits |
| `docs/multi-host-history.md` | Multi-Mac history: host identity, clock handling, retention, queries, export, and limits |
| `docs/app-settings.md` | Settings, navigation and shortcuts, empty and error states, groups, accessibility, the energy review, and what is not verified |
| `Sources/MacFleetKit/Preferences` | Settings values and validation, their storage, and the launch-at-login control (`SMAppService`) |
| `Sources/MacFleetState/Preferences` | The settings model: saves each change, pushes it to the models that use it, and reports load, save, and login-item problems |
| `Sources/MacFleetState/Navigation` | Windows, Settings panes, and the keyboard command table |
| `Sources/MacFleetUI/Settings` | The Settings window: General and Notifications |
| `Sources/MacFleetKit/History/HistoryHost.swift` | Host IDs, ingest outcomes, window summaries, and the fleet storage protocol |
| `Sources/MacFleetKit/History/HistoryCSV.swift` | CSV rendering for the history export |
| `Sources/MacFleetState/History/FleetHistoryModel.swift` | The multi-Mac history model: selection, range, totals, retention, alerts, and export |
| `Sources/MacFleetState/Alerts/HostAlertCenter.swift` | Per-Mac alert settings and state |
| `Sources/MacFleetUI/Fleet/FleetHistoryView.swift` | The History window: charts, comparison, totals, retention, alerts, and export |
| `Sources/MacFleetHeadless` | The `macfleet-headless` command: `run`, `status`, `addresses`, `identity`, `credential`, and `fetch` |
| `Support/launchd` | The LaunchAgent template for the headless agent. `scripts/install-agent.sh` fills it in and installs it for the current user; `--load` starts it |
| `docs/remote-protocol.md` | Protocol specification: identity model, authentication, wire format, compatibility rules, and threat model |
| `Sources/MacFleetKit/Networking` | The JSON snapshot format that `macfleet-agent` writes. The remote protocol has its own format in `Remote` |
| `Sources/MacFleetState/History` | Bounded metric history for charts (`MetricHistory`) |
| `Sources/MacFleetState/Presentation` | Presentation models: display values, spoken wording, usage levels, chart data. No SwiftUI |
| `Sources/MacFleetState/Processes` | `ProcessMonitorModel`: samples processes only while the Processes window is open |
| `Sources/MacFleetState/Alerts` | `AlertEngine` (sustained periods, hysteresis, cooldown, sleep handling) and `AlertCenterModel` (settings, permission, notices) |
| `Sources/MacFleetState` | `FleetStatusModel`: sampling loop, selection, history, and the dashboard presentation |
| `Sources/MacFleetUI/Components` | Reusable views: section card, gauge, sparkline chart, readout row, level badge, colors |
| `Sources/MacFleetUI/Dashboard` | Section cards and the dashboard content view |
| `Sources/MacFleetUI` | Popover (`StatusPopoverView`), menu bar label (`MenuBarLabelView`) |
| `Sources/MacFleetUI/Processes` | The Processes window's view (`ProcessMonitorView`) |
| `Sources/MacFleetUI/Alerts` | The notification thresholds view (`AlertSettingsView`), shown on the Settings window's Notifications pane |
| `Sources/MacFleetUI/Previews` | Preview providers fed by the simulated timeline |
| `Sources/MacFleetAgent` | Command-line agent target |
| `App/MacFleetApp.swift` | Menu bar app entry point (`MenuBarExtra`), the Fleet, History, and Processes windows, the Settings window, and the Navigate commands |
| `MacFleet.xcodeproj` | Xcode application project with Debug and Release configurations |
| `Tests/` | Swift Testing suites for the kit and the state layer |
| `scripts/swiftc-verify.sh` | Verified build, test, and agent-run pipeline using `swiftc` only |
| `scripts/swiftc-benchmark.sh` | Optimized measurement of the per-sample dashboard work |
| `scripts/swiftc-test-runner/main.swift` | Entry point that runs the Swift Testing suites from the script |
| `scripts/swiftc-benchmark/main.swift` | Benchmark driver for the script above |
| `Sources/MacFleetKit/History` | Historical metrics: SQLite store, tiers, rollup, retention, recovery, and history series |
| `Sources/MacFleetKit/Hardware` | GPU devices and memory from Metal, thermal state, capability decisions, and mocked hardware scenarios |
| `scripts/swiftc-history-check.sh` | Crash-consistency checks and storage measurements for the history store |
| `scripts/swiftc-history-check/main.swift` | Driver for the crash checks, the torn-write case, and the benchmark |
| `Config/` | Version metadata (`Version.xcconfig`), signing defaults (`Signing.xcconfig`), and the performance budgets. Local signing overrides go in the git-ignored `Config/Signing.local.xcconfig` |
| `Sources/MacFleetKit/Release` | `MacFleetVersion`, the version the headless agent reports |
| `Support/app` | The `Info.plist` template that `scripts/package-app.sh` fills in |
| `scripts/check-release.sh` | Shell syntax, property lists, and version agreement with the Xcode project. Builds nothing |
| `scripts/package-app.sh` | Release packages in `dist/`: the app and the headless agent, signed and checksummed |
| `scripts/notarize.sh` | Optional notarization of a Developer ID package, using a notarytool profile you create |
| `scripts/install-agent.sh`, `scripts/uninstall-agent.sh` | Plan-first install and removal of the headless agent for the current user |
| `scripts/performance-check.sh` | Runs the benchmarks and fails when a measurement exceeds `Config/performance-budgets.env` |
| `scripts/update-protocol-fixtures.sh`, `scripts/protocol-fixtures/` | Regenerates the protocol 1.0 wire fixtures, which the conformance tests compare byte for byte |
| `.github/workflows/ci.yml` | CI on macOS 15: release files, build and tests, performance budgets, and an ad hoc package |
| `docs/installation.md`, `docs/troubleshooting.md`, `docs/distribution.md` | Installing, common problems, and releasing: signing, notarization, budgets, and CI |
| `docs/verification.md` | What is implemented, verified, partial, and unverified, with the command for each |
| `ROADMAP.md` | Prioritized future work, with scope, dependencies, acceptance criteria, and effort |

## Hardware and thermal state

MacFleet reports only what a documented public API provides. Every measurement has a declared capability: **supported**, **permission needed**, or **not available** on this Mac. A measurement that is not supported is not read, and its reason appears where its value would be, never as zero.

### Sources and capability on the development Mac

The development Mac is an Apple M4 running macOS 27.2.

| Measurement | Public source | Capability here | Reading here |
| --- | --- | --- | --- |
| GPU devices | `MTLCopyAllDevices`; `MTLDevice` name, registry ID, `architecture`, `hasUnifiedMemory`, `supportsRaytracing`, `maxThreadsPerThreadgroup`, `supportsFamily` | Supported | One unified GPU, "Apple M4", architecture `applegpu_g16g`, ray tracing, Apple 1–9, Mac 2, Metal 3 and Metal 4 |
| GPU memory | `recommendedMaxWorkingSetSize` (working-set limit) and `currentAllocatedSize` (Metal allocations) | Supported | Working-set limit 12,713,115,648 bytes; 81,920 bytes allocated |
| Thermal state | `ProcessInfo.thermalState` (nominal, fair, serious, critical) | Supported | Nominal |
| GPU utilization | None. The SDK has no public interface for system-wide GPU utilization. Metal counters measure only work the app submits itself | Not available | No value. The reason is shown |
| CPU temperature | None. macOS has no documented interface for temperature sensors | Not available | No value. The reason is shown |

No measurement this app reads is permission-gated on this Mac, so no live reading is permission-restricted. The permission-restricted state is wired through the reading path and is exercised by mocked hardware in the tests.

### Rules

- No undocumented interface is read. The IORegistry performance statistics and SMC temperature keys are private, so they are not used.
- Apple has deprecated `lowPower`, `headless`, `removable`, and `location` as "not applicable on Apple Silicon". They are not used.
- A working-set limit of zero is reported as "not reported", not as 0 B.
- Thermal state is sampled, not observed. It can lag a change by up to one sampling interval: 2 seconds with the popover open, 10 seconds otherwise.
- A value exists exactly when its capability is supported. The tests check this for every mocked Mac.

### Capability system

`MetricCapability` is `supported`, `permissionRestricted(reason)`, or `unavailable(reason)`. `HardwareCapabilities` holds one per measurement. A source declares its capability before any read, and the provider reads it only when the capability is supported. A read that fails with a permission denial upgrades a supported capability to permission-restricted. Other transient failures keep the capability and show the cause in the reading.

The hardware section is one independent section of the composed snapshot, so it has its own deadline. A hardware section that times out does not delay CPU, memory, storage, or network.

### Measured

- One hardware sample, optimized build, 2,000 calls: about 2.4 µs once Metal is warm. Enumeration with device descriptions averaged 5.7 µs, including the first call's setup.

### Tests

- **Mocked Macs.** Four scenarios: an Apple silicon laptop; a workstation with a discrete GPU, an integrated GPU with no memory limit, mocked supported utilization, and restricted temperature; a virtual machine with no GPU; and a Mac whose GPU enumeration is refused.
- **Gating.** Unavailable and restricted sources are never read. The mocks count their reads to prove it.
- **Capability decisions.** Every transition between the three states, including transient failures that must not change the capability.
- **Presentation.** Every status, reason, and value for each scenario, and a check that no unavailable measurement renders as zero.
- **Live.** Metal reports at least one named GPU with families and a working-set limit. Utilization and temperature are asserted to be unavailable. If a future release adds a public API, this test fails and forces a deliberate change.

### Limitations

- The hardware card was typechecked, not rendered in a running app.
- The permission-restricted path has been exercised only with mocks.
- Only the GPUs Metal enumerates are reported. External GPUs were not present here and are not tested.
- The capability list and every mocked device name are mock values and are labelled as such in the tests.

## Historical metrics

Samples are stored in a SQLite database at `~/Library/Application Support/MacFleet/history.sqlite`, which the app opens at launch.

SwiftData was not used. Its `@Model` macro plugin is not in the Command Line Tools, so it could not be compiled or tested here. SQLite ships in the macOS SDK and needs no installation, and it gives direct control over transactions, integrity checks, and query plans, which the recovery rules depend on.

### What is stored

Each point holds CPU, memory, download and upload rates (summed over monitored interfaces, and missing when any monitored interface lacks a rate, as on the dashboard), and utilization of each browsable, monitored volume. Each value is kept as a sum, count, and maximum, so coarser buckets merge exactly and means are computed when read. A missing reading is stored as a zero count, never as zero.

### Tiers, downsampling, and batching

| Tier | Resolution | Default retention | Built from |
| --- | --- | --- | --- |
| Raw | one point per 10 seconds | 2 days | accepted snapshots |
| Five-minute | 5 minutes | 14 days | raw points |
| Hourly | 1 hour | 90 days | five-minute buckets |

- **Downsampling.** A snapshot closer than 10 seconds to the previous accepted one is skipped. The popover's 2-second cadence therefore writes one point in five.
- **Batching.** Points are buffered and written in one transaction when 32 are waiting, when the oldest has waited 300 seconds, and before any read, rollup, sleep, or shutdown.
- **Rollup.** Only closed buckets are rolled up, in the same transaction as the horizon that records how far the tier is complete, and rollup always runs before pruning.

### Queries

`series(range:now:)` returns one value per slot: 60 one-minute slots for the last hour, 288 five-minute slots for the last day, and 168 hourly slots for the last week. Each range reads one tier. Where the tier has not rolled up the newest part of the range yet, the next finer tier supplies it, so nothing is missing and nothing is counted twice. Range reads use the primary key (checked with `EXPLAIN QUERY PLAN` in the tests).

### Retention

`HistoryRetention` sets each tier's retention. It rejects values below the minimums the charts need: raw 2 hours, five-minute 2 days, hourly 8 days. The local Mac uses the defaults. Each registered Mac can set its own retention in the History window, within the same minimums.

### Recovery

- Each write is one transaction. A write that never reached COMMIT is rolled back when its connection closes. A test checks this directly.
- At open, `PRAGMA quick_check` runs. A damaged file is moved aside with its `-wal` and `-shm` files, as `history.sqlite.damaged-<time>-<id>`, and a new file starts. The history card shows the notice. Nothing is deleted.
- The schema version is stored. A file with an unknown version is not opened.
- Failed writes are kept, up to 1,000 points, counted, and reported in the history card. Live monitoring continues.
- If the file cannot be opened, history falls back to memory for this session, with a notice. If that fails too, history is unavailable, with a notice.

### Threading

`MetricHistoryStore` is an actor. Its SQLite work runs on the actor's executor, never on the main actor. Results cross to the UI as values. The main actor builds at most four charts from at most 288 values per refresh. The one storage call on the main thread is opening the file at launch, which runs the integrity check and upkeep. It took 6.6 ms for a week of data.

The history section reloads at most every 30 seconds while it is open, and never while it is closed.

### Measured

`scripts/swiftc-history-check.sh`, optimized build, development Mac (arm64):

| Measure | Result |
| --- | --- |
| Snapshots offered over 7 days at a 2-second cadence | 302,400 |
| Accepted after 10-second downsampling | 60,480 (241,920 skipped) |
| Transactions for those points | 2,015 |
| Rows written (points plus volume rows) | 181,353 |
| Time inside `save()`, total / mean / slowest | 773.1 ms / 2.6 µs / 3.78 ms |
| Stored after 7 days: raw, five-minute, hourly | 17,281, 2,015, 168 points |
| Series query, median of 20: hour / day / week | 0.26 / 0.32 / 0.23 ms |
| Reopen with integrity check and upkeep | 7.15 ms |
| Files after the run: database / write-ahead log | 3.82 MB / 1.27 MB |
| Resident memory: before / after writes | 6.0 MB / 12.2 MB |

Three Macs ingesting at once, each at a 2-second cadence for seven days, through the same store:

| Measure | Result |
| --- | --- |
| Ingest calls, total wall time | 907,200 calls in 4.5 s (5.0 µs per call) |
| Accepted / throttled | 181,440 / 725,760 |
| Stored per Mac in the aligned window, each with only its own reading | 60,450 each, means 0.200, 0.400, 0.600 |
| 7-day summary per Mac, median of 60 | 0.11 ms |
| Week chart per Mac, median of 60 | 0.15 ms |
| Export of 7 days for three Macs, 1,000-point budget | 2,670 rows in 0.6 ms |

An earlier version batched on a 30-second age, so 10-second points were written four at a time: 16,127 transactions for the same week. The regression test `defaultBatchingWritesFarLessOftenThanEveryFewPoints` pins the fixed default. Restoring the old value makes it fail.

### Crash checks

`scripts/swiftc-history-check.sh` runs three kinds of crash test against real files:

- **Batches**, 30 trials. A writer is killed with SIGKILL at a random moment. Rollups are off, so each commit is exactly one full batch. The file must hold every batch the writer confirmed, at most one more batch, and only whole batches. Result: 30 of 30 consistent.
- **Upkeep**, 30 trials. The same kill, with rollups and pruning running during the writes. Every five-minute bucket must hold exactly the samples of its raw points, counted once. Result: 30 of 30 consistent.
- **Torn**, 5 trials. The writer stages 500 rows in a transaction and kills itself before COMMIT, so the timing is deterministic. The file must hold only the 300 committed points. Result: 5 of 5.

Random kills do not guarantee a kill inside a transaction. The torn trials do, and the in-process rollback test covers the same property.

### Limitations

- A hard crash can lose up to 300 seconds of raw points still in memory. A clean quit and sleep both write them first.
- Timestamps are this Mac's clock. If it moves back more than 5 seconds, new snapshots are held until it passes the last recorded time, and the history card says so. Nothing is stored out of order, but the held snapshots are not stored.
- Rollup and pruning are tested by random kills and by the in-process rollback, not by a deterministic kill inside a rollup transaction.
- Only browsable, monitored volumes are stored.
- If the app is closed for longer than a tier's retention, the missing span stays a gap.
- The history charts were typechecked, not rendered in a running app.
- Measured only over seven simulated days. Longer runs, real sleep and wake cycles, and multi-week file growth were not measured.

## Sampling engine

Sampling is owned by `SamplingEngine` (`Sources/MacFleetKit/Sampling`), an actor that every consumer goes through.

### Rules

- **One collection at a time.** A request made during a collection waits for it and shares its result. Overlapping callers never start a second collection.
- **A deadline on every collection.** The engine races the provider against a 10 s deadline (`collectionDeadline`). A provider that ignores cancellation cannot hold the loop: the deadline returns a failure and the late result is discarded.
- **Sections run concurrently with their own deadline.** `ProcessSystemMetricsProvider` runs CPU, memory, pressure, storage, network, and load in parallel. A section that misses its 2 s deadline reports `.timedOut`, and the other sections still arrive. Only a missing load average fails the whole snapshot.
- **Subscribers get the newest update.** Each subscriber has a stream that keeps one buffered update. A slow consumer never builds a backlog.
- **The loop runs only while someone is subscribed.** It runs at the fastest interval any subscriber asked for, and it stops when the last subscriber leaves.
- **Failures back off.** A failed collection doubles the wait, up to 60 s, and the first success resets it.

### Subscriptions

| Caller | Interval | Lifetime |
| --- | --- | --- |
| Menu bar label | 10 s by default (5, 10, 30, or 60 s in Settings) | While the label exists |
| Popover | 2 s by default (1, 2, or 5 s in Settings) | While the popover is visible |

A subscription lasts as long as its `updates` stream. Releasing the stream, or cancelling the task that consumes it, unsubscribes. Keep the `Subscription` value alive for as long as you want updates.

`SamplingInterval` clamps requested cadences to 0.5 s…3,600 s. Non-finite values fall back to the minimum.

### Sleep, wake, and termination

- **Sleep.** The app observes `NSWorkspace.willSleepNotification` and calls `suspend()`, which cancels the loop. Nothing is scheduled while asleep.
- **Wake.** `NSWorkspace.didWakeNotification` calls `resume()`. Rate baselines are dropped, so no rate spans the sleep, and sampling restarts at once.
- **Detection without notifications.** Each collection compares wall-clock time with awake monotonic time. A wall-clock gap more than 2 s longer than the awake gap is treated as a sleep, and baselines are dropped.
- **Monotonic time.** Rates use `MonotonicTime`, which is `SuspendingClock` (awake time only). A window never counts time spent asleep.
- **Termination.** `applicationShouldTerminate` calls `shutdown()` and replies only after sampling stops, so no collection is cut off mid-write. Power observers are removed in `applicationWillTerminate`.

### Concurrency tests

The engine tests use `ManualScheduler`, which replaces the cadence sleeps with virtual time. Waits and wake-ups are exact, so the tests assert the precise sequence of wait durations rather than relying on real timing. The collection deadline is the one real timer, and its test uses a 100 ms deadline against a provider that never returns.

### Measured overhead

Measured on the development Mac (arm64, 10 logical CPUs, macOS 27.2) with an optimized build (`-O`). The probe runs the real `ProcessSystemMetricsProvider` through the real `SamplingEngine` for 30 s per run, and reads the process's own CPU time (`getrusage`) and resident memory (`mach_task_basic_info`). Three runs per case:

| Case | Collections per 30 s | CPU seconds per 30 s | Share of one core | Resident memory |
| --- | --- | --- | --- | --- |
| 2 s cadence (popover open) | 15–16 | 0.130–0.136 | 0.41–0.45% | 5.9 MB → 10.2–10.4 MB |
| 10 s cadence (menu bar only) | 3 | 0.042–0.045 | 0.13–0.15% | 5.9 MB → 8.3–9.1 MB |
| No subscriber (idle) | 0 | 0.000 | 0.001% | 5.9 MB → 5.2 MB |

The idle row is the no-polling check: with no subscriber the engine made no collections in 30 s.

What these numbers cover: the engine and the provider. They do not cover the menu bar label, the popover, or the SwiftUI rendering, which were not measured. Memory is the resident size at the end of each run, not a peak under long-running load. The 2 s rows include the first-collection warm-up.

### Dashboard

### Menu bar

The menu bar item shows CPU and memory percentages and the aggregate network rate, for example `12% · 50% ↓1.5M ↑40K`. Missing values show a dash rather than zero. Its accessibility label speaks the full values, for example "MacFleet. CPU 12 percent. Memory 50 percent. Download 1.5 megabytes per second, upload 40 kilobytes per second."

### Popover

- **Overview** (always shown): gauges for CPU, memory, and the first monitored disk, plus download and upload rates.
- **Show details**: expands to add these sections, in order:
  - **CPU**: total gauge, a history graph, and a grid of per-core gauges.
  - **Memory**: in-use gauge, used, available and total, the pressure level, and a history graph.
  - **Disks**: each browsable, monitored volume with a gauge, free space, and a removable badge.
  - **Network**: download and upload rates, a dual-line history graph, and each active interface with its address and totals.
  - **System**: host, version, processors, uptime, load averages, and the update time.
  - **Monitored sources**: toggles for every volume and interface, including those hidden from the summary.
- **Refresh** and **Quit** are unchanged. Expanded state is held by the model (`isShowingDetails`), so it survives the popover being redrawn.

### Charts

Charts are `Canvas` sparklines over a fixed history: 120 samples, about four minutes at the two-second sample interval. A missing sample is drawn as a break in the line, never as a drop to zero. Each chart has a text summary for VoiceOver, with the latest and peak values.

### Light and dark mode

Colors are system colors (`.green`, `.orange`, `.red`, `.blue`, `.purple`) and hierarchical fills, which adapt to the appearance. Severity is never shown by color alone: each level pairs its color with a text label and a symbol (checkmark, triangle, or octagon). Previews cover light, dark, overview, and menu bar.

### Accessibility and formatting

- Every gauge, chart, core cell, and interface row has a label and a spoken value. Rows that combine several values read as one element.
- Visible text is short ("12%", "1.5 MB/s"). The spoken wording spells out units ("1.5 megabytes per second").
- Disk and network use decimal units (KB = 1,000 bytes), like Finder. Memory uses binary units (GB = 1,024 MB), like macOS memory displays.
- Text uses semantic fonts, so Dynamic Type applies. Layout is not tied to fixed text sizes.

### Keeping charts responsive

- Each sample does a fixed amount of work: one history append per series and one presentation build. Views read only presentation values and never compute during a body evaluation.
- Histories are bounded at 120 samples per series.
- Charts redraw only when their presentation value changes. The popover samples every two seconds by default (one, two, or five seconds in Settings), so redraws happen at most at that rate.
- The model rebuilds the presentation once per sample and once per source toggle, so a toggle responds immediately.

Measured numbers are in "Responsiveness measurement" below. Rendering time was not measured, because no window or display was driven.

### Previews without monitoring

`SimulatedMetricsTimeline` generates deterministic, realistic metrics: CPU bursts, a slow memory drift, network bursts with cumulative counters, a removable volume, a VPN interface, and an occasional unavailable CPU reading that exercises the gap rendering. `SimulatedSystemMetricsProvider` serves it through the normal provider protocol, and `DashboardPreviewData` builds presentations from it synchronously. No previews touch the system.

## Metrics

| Metric | Source | Definition |
| --- | --- | --- |
| CPU total | `host_statistics(HOST_CPU_LOAD_INFO)` | Busy ticks (user + system + nice) divided by all ticks (busy + idle) over the window since the previous accepted sample |
| CPU per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | The same ratio, computed per logical CPU |
| Memory total | `ProcessInfo.physicalMemory` | Physical memory |
| Memory used | `host_statistics64(HOST_VM_INFO64)` | (anonymous − purgeable + wired + compressor pages) × page size, the breakdown Activity Monitor uses for Memory Used |
| Memory available | Derived | Total − used. Includes free pages and reclaimable file cache |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` | Normal (1), warning (2), or critical (4) |
| Volumes | `FileManager.mountedVolumeURLs` with resource values | Name, mount point, removable flag, browsable flag, total capacity, and available capacity |
| Disk utilization | Derived | (total − available) ÷ total |
| Network interfaces | `getifaddrs` | Name, up/down, loopback, IPv4 addresses |
| Network totals | `sysctl(NET_RT_IFLIST2)` | 64-bit cumulative bytes received and sent per interface |
| Network rates | Derived | Counter deltas ÷ elapsed time between accepted samples |
| Uptime and load average | `ProcessInfo.systemUptime`, `getloadavg` | As before |

### How the derived values work

- **Counters are cumulative.** CPU and network rates come from deltas between samples. CPU counters are 32-bit and wrap, so their deltas use wrapping arithmetic. Network counters are 64-bit.
- **A backwards counter is a reset.** A delta that is not a wrap is reported as `counterReset`, and the next sample recovers. A 32-bit CPU delta of 2³¹ or more is treated as a reset, because a normal interval cannot produce one.
- **Kernel CPU ticks arrive in batches about once a second.** Measured on the development Mac with a 10 ms probe over 12 seconds: small updates arrived every 10–16 ms, and about every second a batch of roughly 900–1,000 ticks landed (about one second of ten cores). A window can therefore see no new ticks. That reading reports "No CPU time elapsed since the last sample" and keeps the previous baseline, so the next reading spans the full interval. The ratio within a batch is still correct.
- **Short windows repeat the last result.** CPU needs a window of at least one second, and network rates need the same. A reading requested sooner repeats the last accepted value instead of computing a noisy percentage from a few ticks.
- **Every metric is a `MetricReading`.** When a read fails, the UI shows the reason rather than 0. Failures are isolated: a failed memory read does not hide CPU, and a failed per-core read keeps the total.
- **Available disk space uses "important usage".** It includes purgeable space, as Finder does. `df` leaves purgeable space out, so its figure is lower.
- **Aggregate network rate is all-or-nothing.** The popover and menu bar sum the rates of every monitored interface, but only when each one has a rate. A partial sum would understate the total, so it is shown as unavailable instead.

### Monitoring selection

Discovery always lists every mounted volume and network interface. `MonitoringSelection` decides which ones are measured:

- Loopback (`lo0`) is excluded by default, because its traffic never crosses a network link.
- Individual volumes and interfaces can be turned off and on from "Monitored sources". Changing a toggle refreshes immediately.
- An excluded item stays in the snapshot with `.notMonitored` and no capacity or rate. Turning it back on starts its baseline over, so its first rate reads "Waiting for a second sample".
- The selection lives in `FleetStatusModel` for the session. It is not saved between launches.
- The `snapshot()` convenience uses `MonitoringSelection.default`. Use `snapshot(selection: .all)` to measure everything, including loopback.

The Disks section lists browsable, monitored volumes. The Network section lists monitored interfaces that have an IPv4 address or have carried traffic, so idle virtual interfaces stay out of the summary. Hidden items remain in "Monitored sources".

### Handling failures

| Situation | Behavior |
| --- | --- |
| A volume disappears between listing and reading | Reported as `volumeDisconnected`. It drops out of the next listing |
| A volume refuses resource reads | Still listed, with `permissionDenied` or `readFailed` on its capacity |
| A volume reports inconsistent capacity | `inconsistentStorageCounters`. Available above total, or zero total |
| Mounted volume list unavailable | Volumes reported as `notProvided`. CPU, memory, and network are unaffected |
| An interface is disconnected | Still listed, marked "(down)", with a zero rate |
| An interface is removed | Dropped from the listing and its baseline discarded |
| An interface has no byte counters | Listed with `notProvided` on its totals and rates |
| Counters move backwards | `counterReset` for that interval; the next interval recovers |
| Interface list unavailable | Network reported with the `getifaddrs` or `sysctl` failure |
| Memory total unknown | Memory usage reported as unavailable, not as a percentage |

Neither `getifaddrs`, `sysctl(NET_RT_IFLIST2)`, nor `FileManager` volume properties need special permissions. The permission and disconnect paths are covered by unit tests with injected failures rather than by revoking real permissions.

## Processes

The Processes window opens from **Processes** in the popover. It lists each process macOS shows to this app, with its PID, name, start time, CPU, and memory footprint. It can be sorted by CPU or memory, searched by name, and grouped by app.

- **Public interfaces only.** The listing uses `proc_listpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDTBSDINFO)`, and `proc_pid_rusage(RUSAGE_INFO_V4)`. It needs no entitlement, no Full Disk Access, and no privileged helper. Nothing terminates a process.
- **Permission boundary.** macOS refuses `proc_pid_rusage` for processes owned by other users and for protected ones. Those rows keep their PID and name, and show "Not permitted by macOS" where CPU and memory would be. Totals count only readings that exist and say how many processes were not permitted.
- **CPU percent.** Percent of one core, as Activity Monitor reports it. It is the change in CPU time over the change in awake time (`MonotonicTime`), so sleep does not inflate it. Process CPU time is in mach absolute ticks, converted to nanoseconds with `mach_timebase_info` (125/3 on Apple silicon). A process has no percentage until its second reading. A window shorter than one second keeps the older baseline and repeats the last percentage.
- **Memory.** The physical footprint (`ri_phys_footprint`), the figure Activity Monitor shows as Memory.
- **Identity.** A process is identified by PID and start time, so a reused PID starts over with no CPU baseline. A process whose start time is not read is identified by PID alone.
- **Changing processes.** A process that exits between listing and reading is left out, and its baseline is dropped. A failed listing shows as one reason, never as an empty list.
- **Sampling.** `ProcessMonitorModel` samples every two seconds by default (two, five, or ten seconds in Settings), only while the window is open. `processesDidDisappear` waits for the loop to stop. Sorting and search rebuild from the last sample and do not sample again.
- **Deliberately not in `SamplingEngine`.** Process listings are not part of `SystemSnapshot`, history, or the wire format, and they run only while the window is open, so they have their own loop. Each sample is awaited before the next starts, so at most one listing is in flight. The libproc calls are synchronous and cannot be cancelled mid-call, so no deadline races them.

### Measured

Development Mac (arm64, macOS 27.2), optimized build, run as a standard user. 433 processes were listed.

| Measure | Result |
| --- | --- |
| Listing, median / slowest of 12 samples | 8.1 ms / 106 ms. The cause of the slowest sample was not checked |
| Readable / permission-restricted | 268 / 165 |
| `/usr/bin/yes` child, CPU per sample, 2 s apart | 97.1–100.0% from the second sample on |
| Presentation build for 433 rows, median / slowest of 50 | 4.2 ms / 14.7 ms, on the main actor, once per sample |

The listing runs on the monitor actor, off the main thread. At this process count, building the presentation took a median of 4.2 ms on the main actor (433 rows, measured with a scratch probe). It has not been re-measured since.

### Tests

- **Aggregation.** Sorting by CPU and memory, with unmeasured processes last and PID tie-breaks. Search ignores case and surrounding spaces and never matches an unreadable name. Totals count only readings that exist. Groups sum their members.
- **Monitor.** The first reading has no percentage. Short windows keep the baseline. Counter resets are reported and recover. A process that exits mid-collection is omitted while the others report. A reused PID starts over. Denied processes keep their PID and name and show reasons. A failed listing is one unavailable snapshot.
- **Live.** This process is listed with its name, a start time in the past, and a footprint. launchd is listed. A busy loop's CPU time matches wall time within 0.5–8×. The bounds are wide because other tests in the same process may add CPU.
- **Presentation and model.** Reasons appear in place of values. Summary and group wording distinguishes "Waiting for a second sample" from "Not permitted by macOS". Empty and failed listings explain themselves. The model samples only while open, and sorting and search do not sample.

### Limitations

- The Processes window was typechecked, not run. Opening and closing it, the popover button, window activation, and sampling stopping when the window closes were not exercised in a running app.
- The app target typechecks with the Command Line Tools SDK (`swiftc -typecheck`). It was not built with Xcode.
- Denied processes were seen on this Mac (165 of 433), but no second user account was available, so the permission boundary was not checked against another user's processes.
- CPU shows "Waiting for a second sample" on every row for the first two seconds.
- The CPU check used one busy child process. Other processes were not compared with another tool.

## Alerts

Alerts announce a resource condition with a native notification. Each alert is configured on the **Notifications** pane of **Settings** (⌘,), also reachable from **Windows** in the popover. Every sample is evaluated, including while the popover is closed, so alerts run whenever the app runs.

| Alert | Measured as | Default threshold | Fires at | Clears only past |
| --- | --- | --- | --- | --- |
| High CPU use | total CPU, percent | 90% | 90% or more | 85% (5-point band) |
| Memory pressure | system pressure level | Critical | Critical | below Critical |
| Low disk space | free share of each browsable, monitored volume | 10% free | 10% free or less | above 12% free (2-point band) |
| High network use | download plus upload across monitored interfaces | 50 MB/s | 50 MB/s or more | below 40 MB/s (80% of threshold) |
| Thermal pressure | `ProcessInfo` thermal state | Serious | Serious or worse | below Serious |

Each alert has its own enable switch, threshold, sustained period, and cooldown. Ranges: CPU 50–100%, memory level 1–2, free disk space 1–50%, network 1–1,000 MB/s, thermal level 1–3. Sustained period 0–600 s, default 30 s. Cooldown 60–3,600 s, default 15 minutes.

- **Sustained period.** The condition must hold for the period, measured with each sample's capture time. Samples arrive every 10 seconds with the popover closed and every 2 seconds with it open, so the period resolves to the sample interval.
- **Hysteresis.** An active alert clears only when the reading passes the band in the table. Pressure and thermal states are discrete, so their band is the level itself.
- **Cooldown.** At most one notice per alert in each cooldown. A notice that comes due during the cooldown waits, and is sent when the cooldown ends if the alert is still firing. If the alert clears first, the waiting notice is dropped. An alert that re-enters within the cooldown waits for it in the same way.
- **One notice per episode.** Clearing sends no notice. A new episode is announced only after its sustained period and the cooldown.
- **Sleep.** A gap of more than 60 seconds between samples restarts any sustained period. No period counts across sleep.
- **Unavailable readings.** They never clear an active alert and are never read as zero. They break a sustained period in progress.
- **Per volume.** Each browsable, monitored volume has its own disk alert, and an alert ends when its volume is gone or unmonitored.
- **Permission.** The app never asks for notification permission at launch or when an alert is enabled. Only the **Allow Notifications** button asks, through `UNUserNotificationCenter.requestAuthorization`. Without permission, nothing is posted, but the settings window still shows the last alert. A repeated alert replaces its earlier notification rather than stacking.
- **Storage.** Settings are saved at once as one encoded value under the `MacFleet.alertSettings` key in user defaults. Unreadable saved data falls back to the defaults, and the settings window says so. Values are clamped into their ranges on every change and on load.

### Tests

- **Settings.** Ranges and clamping, non-finite values, JSON round trip, files that omit metrics, unknown metric names, damaged data, and a user-defaults round trip in a throwaway suite.
- **Engine, with a simulated clock and synthetic streams.** Sustained periods, restart after one sample below the threshold, the hysteresis band, cooldown deferral and dropping, a new episode after the cooldown, unavailable readings, a sleep gap, disabling, per-volume alerts, unmonitored volumes, the network total with a missing interface, memory and thermal levels, and a 4,000-second swinging load replayed twice. The replay gives the same notices, and consecutive notices are at least one cooldown apart.
- **Model.** Settings persist into a new model, values are clamped, switches are per metric, unreadable and unsaved settings are reported, permission is read without asking and requested only on request, nothing is posted without permission, posted notices carry their message and cooldown, and a failed post is reported.
- **Status model.** A sustained breach reaches the notifier through the normal refresh path.
- **Presentation.** Row order and labels, status words, timing wording, notification wording, and the last-alert line.

### Limitations

- Notification delivery was not run. The app is not bundled here, so `UserNotificationAlertNotifier` compiles and is covered by its status mapping, but the permission prompt and banners were not seen.
- The Settings window and the Windows menu were typechecked, not rendered. No XCUITest target was added, because neither Xcode nor `xcodebuild` is available here.
- Launch at login was not registered, since a test run must not change login items. The `SMAppService` path is covered through its state mapping only.
- No notice is sent when an alert clears. Recovery notices were left out to keep notifications rare.
- Hysteresis margins are fixed in code, not settings. A sustained period is only as precise as the sample interval.
- The engine's cost per sample was not measured.

## Remote monitoring protocol

MacFleet can serve its metric snapshots to an authenticated client over TLS. The protocol is versioned (1.0) and carries JSON messages in length-prefixed frames. It lives in `MacFleetKit` (`Sources/MacFleetKit/Remote`) and has no SwiftUI dependency. The headless agent (below) runs a host. The full specification, including the identity model, the authentication design, the compatibility rules, and the threat model, is in [docs/remote-protocol.md](docs/remote-protocol.md).

- **Host identity.** The host holds a PKCS#12 bundle with an RSA-2048 certificate. A client pins the SHA-256 fingerprint of that certificate. There is no certificate authority and no trust on first use. The bundle is imported in memory only, which needs macOS 15.
- **Client authentication.** Each client has a 256-bit secret. Each side proves it holds the secret with HMAC-SHA256 over a transcript that covers the session and the TLS channel binding. The host proves it too, and the client checks that proof before it accepts anything.
- **Nothing before authentication.** The host sends no metrics or capabilities until the client's proof verifies.
- **Private networks.** The host closes connections from outside loopback and the Tailscale ranges (`100.64.0.0/10` and `fd7a:115c:a1e0::/48`) before it reads a byte.
- **Limits.** Frames are capped at 1 MiB and sessions at 8. Every handshake step, the idle timeout, and the TLS start have deadlines.

### Limitations

- Not verified on a real tailnet. The Tailscale ranges are unit-tested, and loopback is tested end to end.
- Certificate expiry was not tested, and EC identities did not import in testing. Only RSA identities are supported.
- Failed authentication attempts are logged by the headless agent, but they are not rate-limited, and there is no revocation list beyond removing a credential.
- The app does not run a host. The headless agent does, and its secrets are kept in the keychain or an owner-only file (see below).

## Multi-Mac fleet dashboard

The **Fleet** window (opened from **Windows** in the popover) shows this Mac beside every remote Mac you register. A remote Mac is added by its Tailscale name or private IP address, and its certificate is trusted only after you compare its fingerprint with `macfleet-headless identity show` on that Mac. Each remote Mac keeps its own connection, snapshot, and retry clock. Transient failures retry with backoff, from 2 seconds up to 300. Failures that retries cannot fix stop and say what to do. The full guide, with the failure table and the limits, is [docs/fleet-dashboard.md](docs/fleet-dashboard.md).

- **Trust.** Trust on first use, with the fingerprint shown for confirmation. A changed certificate is untrusted until reviewed, and an expired one is rejected by name.
- **Storage.** The address, pin, and label are in user defaults. The client secret is in the login keychain, under its own service.
- **Limits.** At most 16 remote Macs. The address is not resolved, so a name that resolves to a public address is not refused.

### Limitations

- The Fleet window was typechecked, not run, and the keychain store was not exercised by the automated tests.
- Not verified on a real tailnet or with two physical Macs.

## Multi-Mac history

Each Mac has its own stored history, keyed by a stable host ID: `local` for this Mac and the record ID of each registered Mac. Rows from different Macs are never combined. The **History** window (Windows > History) charts each selected Mac, compares up to four side by side, shows totals across Macs, sets retention and alert settings per Mac, and exports CSV. A remote sample is placed by the time this Mac received it, so a skewed clock on that Mac never reorders its history. The offset is shown when it exceeds a minute. Removing a Mac deletes its history and alert settings. The detail, the query rules, and the limits are in [docs/multi-host-history.md](docs/multi-host-history.md).

### Limitations

- The History window was typechecked, not run. The CSV save panel was not exercised.
- Totals are exact for windows aligned to five-minute boundaries. The app's windows are aligned, so this matters only for custom queries.
- A Mac that stops reporting keeps its newest open bucket until it reports again.
- A clock that moves back more than 5 seconds holds new snapshots until it catches up.
- The fleet benchmark uses simulated readings. Not verified on a tailnet or with physical Macs.

## Headless agent

`macfleet-headless` is a separate command-line executable for running MacFleet without the menu bar. It samples the Mac at a configured interval, serves the latest sample to authenticated clients over TLS, writes a health report and a JSON-lines log, and stops cleanly on SIGTERM or SIGINT. The full guide is [docs/headless-agent.md](docs/headless-agent.md).

- **No listener by default.** A listener needs an explicit numeric address that is assigned to this Mac, such as the Tailscale address. Wildcards are refused.
- **Private networks.** Clients must come from loopback or the Tailscale ranges, unless `allowedNetworks` says otherwise.
- **Secrets.** The identity passphrase and each client secret go to the login keychain or to an owner-only file. The configuration file holds no secrets. The secret commands print nothing except the new client secret, once.
- **Health and logs.** The status file is rewritten on every change and sample, and `status` applies the freshness rules. The log is owner-only, and it rotates at 5 MB.
- **Shutdown.** Connected clients receive a `shuttingDown` notice before their sessions close.
- **Automatic start.** `scripts/install-agent.sh` fills in `Support/launchd/com.macfleet.headless.plist` and installs it for the current user, and `--load` starts it. The steps are in [docs/installation.md](docs/installation.md). Loading under launchd has not been tried on this Mac.

### Limitations

- The launchd template lints, but it was not installed or loaded.
- The keychain store compiles, but automated tests do not change the keychain, so it was not exercised.
- Not verified on a real tailnet or from another Mac.
- Login behaviour, such as whether the listener is ready before Tailscale connects, was not observed.

## Verified commands

Run from the repository root.

```sh
scripts/swiftc-verify.sh
scripts/swiftc-benchmark.sh
scripts/swiftc-history-check.sh
scripts/check-release.sh
scripts/performance-check.sh
scripts/package-app.sh
```

`scripts/swiftc-verify.sh` typechecks the manifest, builds `MacFleetKit` and `MacFleetState` as dylibs, typechecks `MacFleetUI` (including the dashboard, components, and previews), builds and runs `macfleet-agent`, builds `macfleet-headless`, compiles and runs the Swift Testing suites, then runs `scripts/headless-smoke.sh`, which starts the headless agent as its own process and checks it end to end. It exits non-zero on the first failure. Outputs go to `.agent-local/swiftc-build/`, which is git-ignored. Remove it with `rm -rf .agent-local/swiftc-build`.

`scripts/check-release.sh` checks shell syntax, the property lists, and that the version agrees between `Config/Version.xcconfig`, the Xcode project, and the Swift constants. It builds nothing.

`scripts/performance-check.sh` builds the optimized benchmarks and fails when a measurement exceeds `Config/performance-budgets.env`.

`scripts/package-app.sh` writes the app and headless packages to `dist/`. It signs them ad hoc unless a Developer ID is supplied, verifies the signatures and the reported version, and writes checksums. `scripts/notarize.sh` needs a Developer ID and a notarytool profile, and was not run here. CI (`.github/workflows/ci.yml`) runs these on macOS 15 with the Command Line Tools. It has not run on GitHub from this repository.

`scripts/swiftc-benchmark.sh` builds the kit and state layers with optimization and runs the dashboard benchmark. Its outputs are removed on exit.

`scripts/swiftc-history-check.sh` builds MacFleetKit with optimization and runs the crash checks and the seven-day storage benchmark described under Historical metrics. `TRIALS` sets the number of random kill trials per pattern (default 30). Outputs are removed on exit. It takes a few minutes.

The script uses the Command Line Tools SDK by default. Override with `DEV=/path/to/Developer` or `SDK=/path/to/MacOSX.sdk`.

Last run result (release review): manifest, all modules, the UI typecheck, and the agent passed with no compiler warnings. All 727 Swift Testing tests in 154 suites passed (33 of them cover processes, 47 cover alerts, 70 cover the remote protocol, 52 cover the headless agent, 70 cover the fleet dashboard, including real loopback sessions, 61 cover multi-host history, and 62 cover settings, navigation, groups, and accessibility; the other 332 cover the earlier layers, and 37 were added for the release work), including live tests that call the real Mach, FileManager, and getifaddrs/sysctl APIs on this Mac. The sampling tests are deterministic (virtual time). The app target typechecks in the same review, with no `@State` to replace (see the limitation below).

The test suites cover:

- Utilization and rate calculations: busy share, nice ticks, rollover from 2³² to 0, resets, zero elapsed ticks or time, core-count changes, and per-core failures.
- Trackers: first sample, minimum window, empty windows that keep the baseline, interfaces appearing and disappearing, and counter resets that recover.
- Disk capacity: utilization, zero total, available above total, and missing values.
- Byte and percent formatting: decimal and binary units, compact menu bar forms, unit boundaries, and rounding up to the next unit.
- Spoken formatting: unit wording, rates, percentages, and uptime.
- Failure mapping for volume resource errors: permission denied, missing file, and other errors.
- Provider behavior with scripted sources and a manual clock, so rates are exact.
- Presentation models: usage levels and thresholds, CPU core labels, memory amounts and pressure badges, disk rows and free-space text, network rows and hidden interfaces, aggregate rates with partial failures, chart ceilings, menu bar text and its accessibility label, uptime and load text, and the sources toggles.
- Metric history: bounded series, gaps stored as missing rather than zero, and network sums that are gaps when partial.
- Simulated metrics: determinism, physical ranges, growing counters, the deliberate CPU gap, and default exclusions.
- The monitoring selection, its JSON round trip, and the model: dashboard built on refresh, history capacity, source toggles that rebuild immediately, and the expanded state.
- The sampling loop, which stops when cancelled.
- Fleet dashboard: address and record validation and storage, the identity probe over TLS, certificate change and expiry, failure classification, backoff, the connection loop with a manual clock (reconnection, failed authentication, unavailable hosts, dropped sessions, and stopping), pairing, removal, launch reconnection, per-Mac independence, the unified presentation, and loopback integration tests with simultaneous Macs on ports 21444 to 21450.
- Headless agent: configuration validation, secret store permissions, structured log format and rotation, health rules, local address classification, and in-process integration tests that run a real agent and real TLS clients on loopback ports 21421 to 21432, covering snapshots, the status report, a disabled listener, a wrong secret, a disconnecting client, graceful shutdown with the notice, a failed sample, a listener that cannot bind, a missing secret, a second run, and an untrusted pin.
- Remote protocol: every message's encoding, the envelope and date format on the wire, compatibility with unknown types, fields, and error codes, framing and the frame limits, version negotiation, the authentication proofs and transcript binding, credential and fingerprint validation, the network policy, identity import and pin acceptance, and loopback TLS sessions. The sessions cover a full handshake, refused credentials, a wrong pin, a refused network, a version mismatch, no metrics before authentication, an idle client, heartbeats, and teardown. The loopback suite is serialized and uses ports 21401–21411. Its identity tests need macOS 15.
- Alerts: settings values and persistence, the engine's sustained periods, hysteresis, cooldown, sleep and unavailable handling with a simulated clock, the model's permission and posting paths, the status model's path, and the presentation wording (see Alerts).
- Processes: aggregation, sorting, search, and totals; the monitor's CPU windows, counter resets, exits during collection, PID reuse, and denied and failed listings; a live listing of this process and a busy-loop CPU check; presentation wording; and the model's sampling lifecycle.
- Release and packaging: version agreement across `Config/Version.xcconfig`, the Xcode project, and the Swift constants; the CI workflow's runner and toolchain; script syntax and property lists; the protocol 1.0 fixtures, compared byte for byte; the agent installer and uninstaller in a scratch folder, including the template path in a package, purge safety, and damaged manifests; the headless configuration's defaults; and the deadline race, including work that ignores cancellation.

## Responsiveness measurement

`scripts/swiftc-benchmark.sh` times the work done once per sample: appending to the bounded history and building the dashboard presentation. System reads are excluded, and the inputs are generated before timing starts. Optimized build (`-O`), 2,000 samples, 120-sample history, on the development Mac, two runs:

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Mean per sample | 46.9 µs | 48.6 µs |
| Median per sample | 45.0 µs | 44.0 µs |
| 95th percentile | 51.0 µs | 61.0 µs |
| Worst single sample | 2.4 ms | 3.1 ms |

Both runs were taken in the release review. Each has one worst sample of 2.4 to 3.1 ms among 2,000, and its cause is not known. The median is the figure the budget gates (a 2 ms ceiling, in `Config/performance-budgets.env`). The history stayed at 120 samples per series. These numbers cover data work only. Rendering the charts and the popover was not measured, because no display was driven, so frame rates are unverified.

## Accuracy check against system tools

Taken on the development Mac (arm64, 10 logical CPUs, 16 GB, macOS 27.2 build 26B123). All figures are single samples, not averages.

- **CPU:** agent total 10.5%. `iostat -c 2 -w 2` over a 2-second interval reported 6% user + 4% system = 10% busy. The agent's per-core mean (10.5%) matches its total.
- **Memory:** agent used 11.65 GB. `vm_stat` anonymous, purgeable, wired, and compressor page counts give about 11.67 GB. The difference is from counts changing between reads.
- **Pressure:** agent reported 1 (normal). The agent reads the same sysctl that `memory_pressure` uses, so this is not an independent cross-check.
- **Root volume capacity:** the agent's total (245,107,195,904 bytes) equals `df -k` exactly (239,362,496 KiB). The agent's available figure (184.0 GB) is higher than `df`'s (177,449,860 KiB ≈ 181.7 GB) because it includes purgeable space.
- **Interface totals:** agent `en1` received 2,119,218,176 bytes and sent 3,296,602,112. `netstat -ib -I en1`, read a few seconds later, gave 2,128,060,123 and 3,303,521,091. The gap is traffic between the two reads.
- **Rates:** not cross-checked with an independent rate tool. The `en1` rates were 0.36 MB/s received and 1.67 MB/s sent.

`top` cannot run inside the sandbox ("Operation not permitted"), so it was not used for comparison.

## Known limitation: SwiftPM in restricted sandboxes

`swift build`, `swift test`, and `swift run macfleet-agent` do not complete in the restricted repository sandbox. Checked in the release review with the Command Line Tools toolchain (Swift 6.4.2):

- SwiftPM runs each package manifest inside its own `sandbox-exec`, and this sandbox refuses to nest one (`sandbox_apply: Operation not permitted`). `--disable-sandbox` turns off only that inner manifest sandbox, and the repository's outer sandbox still applies. With it, the manifest compiles and the test fixtures are declared, so the unhandled-file warning is gone.
- The build then stops in the build service. The default build system reports `unable to write manifest to .../XCBuildData/...` (EPERM).
- `--build-system native` stops with `I/O error ... output-file-map.json`.

Cause of the build-service failure: Foundation's atomic writes (`Data.write(options: .atomic)`, `FileManager.createFile`) and item-replacement directories fail with EPERM in this sandbox. Plain writes, `rename`, `renamex_np`, `flock`, `fcntl` locks, and symlinks all work. SwiftPM relies on the failing path. The fix belongs to the sandbox or toolchain, not the repository.

On a Mac with full Xcode, `swift test` and `swift run macfleet-agent` are expected to work. This project has not run them.

## Known limitation: SwiftData

SwiftData is not used. Its `@Model` macro plugin is missing from the Command Line Tools, so storage cannot be built or tested here with that framework. History uses SQLite (see Historical metrics). A full Xcode build could use SwiftData, but that would be a new storage layer, not a drop-in change.

## Known limitation: SwiftUI macros in the Command Line Tools

The Command Line Tools do not ship the SwiftUI macro plugin, so `@State` cannot be expanded there. A minimal probe fails with `StateMacro` not found, as checked in the release review. For that reason the UI module uses no property wrappers. Views take presentation values and action closures, and the model holds the expanded state. The app target uses no `@State`, so it typechecks with the Command Line Tools.

## Build and launch the menu bar app (full Xcode)

A full build of the app needs Xcode for `xcodebuild`, signing, and running the app. The packaged app, built by `scripts/package-app.sh`, does not need Xcode.

1. Open `MacFleet.xcodeproj` in Xcode.
2. Select the `MacFleet` scheme and the `My Mac` destination.
3. Press Run (⌘R), or build from the command line:

   ```sh
   xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build
   ```

4. Launch the built `MacFleet.app` from the `DerivedData` products folder shown in the build log. The app has no Dock icon (`LSUIElement`). Its menu bar item shows the compact statistics. Click it to open the popover, use Show details to expand it, then use Refresh or Quit.

The menu bar label starts a sampling loop that refreshes every 10 seconds by default (5, 10, 30, or 60 seconds in Settings). The popover samples every two seconds by default (1, 2, or 5 seconds), and Refresh samples now.

Not verified in this environment: the Xcode build, the app's windows and menu bar in a running app, the popover layout, the charts' appearance, light and dark mode, the Processes, Fleet, History, and Settings windows on screen, the Navigate shortcuts, notifications appearing, and launch at login. The packaged app was launched once for four seconds without a library-loading error, which is the only run-time check made. The views and previews typecheck as a module, and the app target typechecks. Nothing was rendered. The full status of each area is in [docs/verification.md](docs/verification.md).

## Run the agent

With full Xcode:

```sh
swift run macfleet-agent
```

Without SwiftPM, the verified script builds the agent at `.agent-local/swiftc-build/macfleet-agent`. The agent takes two samples two seconds apart so CPU and network rates are available, prints one JSON snapshot to standard output, and exits. Exit status is 1 with a message on standard error if the load average cannot be read. The snapshot measures every volume and interface, including loopback.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `MACFLEET_BUNDLE_ID` in `Config/Version.xcconfig` and the Xcode project together. `scripts/check-release.sh` fails if they disagree.
- The app is ad-hoc signed by default (`Config/Signing.xcconfig`). No team is configured. No Developer ID or notarization has been run. See [docs/distribution.md](docs/distribution.md).
- The menu bar icon is an SF Symbol (`server.rack`) rather than a custom asset.
- Snapshots are local to this Mac. The remote protocol is implemented in `MacFleetKit`, and the headless agent serves it. The menu bar app does not serve it. `FleetWireFormat` still defines the `macfleet-agent` JSON payload.
- Memory now uses the binary formatter everywhere, so a memory total shows as "16 GB". The earlier popover used the system memory style, which can differ slightly.
- Usage is shown as Elevated from 75% and Critical from 90%, for CPU, memory, and disks alike. Pressure maps warning to elevated and critical to critical.
- Not included: interface MAC addresses, IPv6 addresses, wireless details, per-volume I/O throughput, and per-process network use.
- The Xcode project has no test targets. Tests run through `scripts/swiftc-verify.sh` or `swift test`.
- Alert settings live in user defaults under `MacFleet.alertSettings`, not in a file, so they are per user account on this Mac. Per-Mac alert settings use `MacFleet.hostAlertSettings`. The alert hysteresis margins and the sustained and cooldown limits are fixed in code and in `AlertRule`.
- The Xcode project file is hand-written. It passes `plutil -lint`, but Xcode has not opened it here.
- Snapshot JSON has gained `cpu`, `memory`, `memoryPressure`, `volumes`, `network`, and `hardware` fields. Payloads from earlier builds without them no longer decode. No deployed consumers existed.
- `snapshot()` changed to `snapshot(selection:)` as the protocol requirement. The no-argument form remains as a convenience, so existing call sites are unchanged.

## License

MacFleet is released under the MIT License. The full text is in [LICENSE](LICENSE). Copyright (c) 2026 Mykyta Kizilov. The
packages include a copy of the license: `MacFleet.app/Contents/Resources/LICENSE` and the root of the headless archive.

## Third-party software

MacFleet has no third-party source code and no third-party dependencies, so there are no third-party notices to carry. It
links only what ships with macOS: the system SQLite library (`libsqlite3`), and Apple's frameworks such as Foundation,
Network, Security, Metal, and SwiftUI. Nothing from another project is copied into the repository. The tools the checks use
(the Command Line Tools, `openssl`, `perl`, and the gitleaks history scan) are not distributed with the project.
