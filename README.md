# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. Its menu bar item shows CPU, memory, and network rates at a glance. The popover shows an overview, and a details view adds graphs, per-core load, storage, network, and the system summary. A separate command-line agent prints the same snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`), for building and running the app bundle

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
| `docs/remote-protocol.md` | Protocol specification: identity model, authentication, wire format, compatibility rules, and threat model |
| `Sources/MacFleetKit/Networking` | Wire format for snapshots (no transport yet) |
| `Sources/MacFleetState/History` | Bounded metric history for charts (`MetricHistory`) |
| `Sources/MacFleetState/Presentation` | Presentation models: display values, spoken wording, usage levels, chart data. No SwiftUI |
| `Sources/MacFleetState/Processes` | `ProcessMonitorModel`: samples processes only while the Processes window is open |
| `Sources/MacFleetState/Alerts` | `AlertEngine` (sustained periods, hysteresis, cooldown, sleep handling) and `AlertCenterModel` (settings, permission, notices) |
| `Sources/MacFleetState` | `FleetStatusModel`: sampling loop, selection, history, and the dashboard presentation |
| `Sources/MacFleetUI/Components` | Reusable views: section card, gauge, sparkline chart, readout row, level badge, colors |
| `Sources/MacFleetUI/Dashboard` | Section cards and the dashboard content view |
| `Sources/MacFleetUI` | Popover (`StatusPopoverView`), menu bar label (`MenuBarLabelView`) |
| `Sources/MacFleetUI/Processes` | The Processes window's view (`ProcessMonitorView`) |
| `Sources/MacFleetUI/Alerts` | The Alert Settings window's view (`AlertSettingsView`) |
| `Sources/MacFleetUI/Previews` | Preview providers fed by the simulated timeline |
| `Sources/MacFleetAgent` | Command-line agent target |
| `App/MacFleetApp.swift` | Menu bar app entry point (`MenuBarExtra`), the Processes window, and the Alert Settings window |
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

`HistoryRetention` sets each tier's retention. It rejects values below the minimums the charts need: raw 2 hours, five-minute 2 days, hourly 8 days. The app uses the defaults. Retention is configurable in code but not yet in the UI.

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
| Time inside `save()`, total / mean / slowest | 671.6 ms / 2.2 µs / 3.83 ms |
| Stored after 7 days: raw, five-minute, hourly | 17,281, 2,015, 168 points |
| Series query, median of 20: hour / day / week | 0.23 / 0.29 / 0.21 ms |
| Reopen with integrity check and upkeep | 6.62 ms |
| Files after the run: database / write-ahead log | 3.34 MB / 1.94 MB |
| Resident memory: before / after writes | 5.9 MB / 11.0 MB |

An earlier version batched on a 30-second age, so 10-second points were written four at a time: 16,127 transactions for the same week. The regression test `defaultBatchingWritesFarLessOftenThanEveryFewPoints` pins the fixed default. Restoring the old value makes it fail.

### Crash checks

`scripts/swiftc-history-check.sh` runs three kinds of crash test against real files:

- **Batches**, 20 trials. A writer is killed with SIGKILL at a random moment. Rollups are off, so each commit is exactly one full batch. The file must hold every batch the writer confirmed, at most one more batch, and only whole batches. Result: 20 of 20 consistent.
- **Upkeep**, 20 trials. The same kill, with rollups and pruning running during the writes. Every five-minute bucket must hold exactly the samples of its raw points, counted once. Result: 20 of 20 consistent.
- **Torn**, 5 trials. The writer stages 500 rows in a transaction and kills itself before COMMIT, so the timing is deterministic. The file must hold only the 300 committed points. Result: 5 of 5.

Random kills do not guarantee a kill inside a transaction. The torn trials do, and the in-process rollback test covers the same property.

### Limitations

- A hard crash can lose up to 300 seconds of raw points still in memory. A clean quit and sleep both write them first.
- Timestamps are wall-clock. A backward clock jump is accepted, but it can leave points below an already rolled-up horizon as raw points that are never rolled up. They are pruned with the raw tier.
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
| Menu bar label | 10 s (`SamplingInterval.background`) | While the label exists |
| Popover | 2 s (`SamplingInterval.interactive`) | While the popover is visible |

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
- Charts redraw only when their presentation value changes. Sampling runs every two seconds, so redraws happen at most at that rate.
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
- **Sampling.** `ProcessMonitorModel` samples every two seconds only while the window is open. `processesDidDisappear` waits for the loop to stop. Sorting and search rebuild from the last sample and do not sample again.
- **Deliberately not in `SamplingEngine`.** Process listings are not part of `SystemSnapshot`, history, or the wire format, and they run only while the window is open, so they have their own loop. Each sample is awaited before the next starts, so at most one listing is in flight. The libproc calls are synchronous and cannot be cancelled mid-call, so no deadline races them.

### Measured

Development Mac (arm64, macOS 27.2), optimized build, run as a standard user. 433 processes were listed.

| Measure | Result |
| --- | --- |
| Listing, median / slowest of 12 samples | 8.1 ms / 106 ms. The cause of the slowest sample was not checked |
| Readable / permission-restricted | 268 / 165 |
| `/usr/bin/yes` child, CPU per sample, 2 s apart | 97.1–100.0% from the second sample on |
| Presentation build for 433 rows, median / slowest of 50 | 4.2 ms / 14.7 ms, on the main actor, once per sample |

The listing runs on the monitor actor, off the main thread. At this process count the window costs about 4 ms of main-thread work every two seconds.

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

Alerts announce a resource condition with a native notification. Each alert is configured in the **Alert Settings** window, opened from **Windows** in the popover. Every sample is evaluated, including while the popover is closed, so alerts run whenever the app runs.

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
- The Alert Settings window and the Windows menu were typechecked, not rendered.
- No notice is sent when an alert clears. Recovery notices were left out to keep notifications rare.
- Hysteresis margins are fixed in code, not settings. A sustained period is only as precise as the sample interval.
- The engine's cost per sample was not measured.

## Remote monitoring protocol

MacFleet can serve its metric snapshots to an authenticated client over TLS. The protocol is versioned (1.0) and carries JSON messages in length-prefixed frames. It lives in `MacFleetKit` (`Sources/MacFleetKit/Remote`) and has no SwiftUI dependency. No app or agent command starts a host or client yet. The full specification, including the identity model, the authentication design, the compatibility rules, and the threat model, is in [docs/remote-protocol.md](docs/remote-protocol.md).

- **Host identity.** The host holds a PKCS#12 bundle with an RSA-2048 certificate. A client pins the SHA-256 fingerprint of that certificate. There is no certificate authority and no trust on first use. The bundle is imported in memory only, which needs macOS 15.
- **Client authentication.** Each client has a 256-bit secret. Each side proves it holds the secret with HMAC-SHA256 over a transcript that covers the session and the TLS channel binding. The host proves it too, and the client checks that proof before it accepts anything.
- **Nothing before authentication.** The host sends no metrics or capabilities until the client's proof verifies.
- **Private networks.** The host closes connections from outside loopback and the Tailscale ranges (`100.64.0.0/10` and `fd7a:115c:a1e0::/48`) before it reads a byte.
- **Limits.** Frames are capped at 1 MiB and sessions at 8. Every handshake step, the idle timeout, and the TLS start have deadlines.

### Limitations

- Not verified on a real tailnet. The Tailscale ranges are unit-tested, and loopback is tested end to end.
- Certificate expiry was not tested, and EC identities did not import in testing. Only RSA identities are supported.
- Failed authentication attempts are not rate-limited or logged, and there is no revocation list beyond removing a credential.
- Secrets and identities are held in memory by the caller. Keychain storage is not implemented.
- No entry point runs a host or client, and no configuration is persisted.

## Verified commands

Run from the repository root.

```sh
scripts/swiftc-verify.sh
scripts/swiftc-benchmark.sh
scripts/swiftc-history-check.sh
```

`scripts/swiftc-verify.sh` typechecks the manifest, builds `MacFleetKit` and `MacFleetState` as dylibs, typechecks `MacFleetUI` (including the dashboard, components, and previews), builds and runs `macfleet-agent`, then compiles and runs the Swift Testing suites. It exits non-zero on the first failure. Outputs go to `.agent-local/swiftc-build/`, which is git-ignored. Remove it with `rm -rf .agent-local/swiftc-build`.

`scripts/swiftc-benchmark.sh` builds the kit and state layers with optimization and runs the dashboard benchmark. Its outputs are removed on exit.

`scripts/swiftc-history-check.sh` builds MacFleetKit with optimization and runs the crash checks and the seven-day storage benchmark described under Historical metrics. `TRIALS` sets the number of random kill trials per pattern (default 20). Outputs are removed on exit. It takes a few minutes.

The script uses the Command Line Tools SDK by default. Override with `DEV=/path/to/Developer` or `SDK=/path/to/MacOSX.sdk`.

Last run result: manifest, all modules, the UI typecheck, and the agent passed with no compiler warnings. All 445 Swift Testing tests in 104 suites passed (33 of them cover processes, 47 cover alerts, and 70 cover the remote protocol), including live tests that call the real Mach, FileManager, and getifaddrs/sysctl APIs on this Mac. The sampling tests are deterministic (virtual time), and the full pipeline passed five consecutive runs. The app entry point also typechecks with `@State` replaced by a plain property (see the limitation below).

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
- Remote protocol: every message's encoding, the envelope and date format on the wire, compatibility with unknown types, fields, and error codes, framing and the frame limits, version negotiation, the authentication proofs and transcript binding, credential and fingerprint validation, the network policy, identity import and pin acceptance, and loopback TLS sessions. The sessions cover a full handshake, refused credentials, a wrong pin, a refused network, a version mismatch, no metrics before authentication, an idle client, heartbeats, and teardown. The loopback suite is serialized and uses ports 21401–21411. Its identity tests need macOS 15.
- Alerts: settings values and persistence, the engine's sustained periods, hysteresis, cooldown, sleep and unavailable handling with a simulated clock, the model's permission and posting paths, the status model's path, and the presentation wording (see Alerts).
- Processes: aggregation, sorting, search, and totals; the monitor's CPU windows, counter resets, exits during collection, PID reuse, and denied and failed listings; a live listing of this process and a busy-loop CPU check; presentation wording; and the model's sampling lifecycle.

## Responsiveness measurement

`scripts/swiftc-benchmark.sh` times the work done once per sample: appending to the bounded history and building the dashboard presentation. System reads are excluded, and the inputs are generated before timing starts. Optimized build (`-O`), 2,000 samples, 120-sample history, on the development Mac, two runs:

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Mean per sample | 39.2 µs | 43.2 µs |
| Median per sample | 36.0 µs | 40.0 µs |
| 95th percentile | 43.0 µs | 53.0 µs |
| Worst single sample | 3.1 ms | 2.8 ms |

Both runs show a worst-case sample of about 3 ms. That is consistent with a one-time warm-up, but I did not verify the cause. The history stayed at 120 samples per series. Those numbers cover data work only. Rendering the charts and the popover was not measured, because no display was driven. Frame rates are unverified.

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

`swift build`, `swift test`, and `swift run macfleet-agent` do not work in the current restricted repository sandbox. Two failures were observed with the Command Line Tools toolchain (Swift 6.4.2):

- Default build system: `unexpected service error: unable to write manifest to .../XCBuildData/.../manifest.json` (EPERM).
- `--build-system native`: `I/O error ... output-file-map.json`, because SwiftPM never produces that file.

Cause: Foundation's atomic writes (`Data.write(options: .atomic)`, `FileManager.createFile`) and item-replacement directories fail with EPERM in this sandbox. Plain writes, `rename`, `renamex_np`, `flock`, `fcntl` locks, and symlinks all work. SwiftPM relies on the failing path. The fix belongs to the sandbox or toolchain, not the repository.

SwiftPM is expected to work on a normal Mac with full Xcode. That expectation is unverified here. On such a machine, run `swift test` and `swift run macfleet-agent`.

## Known limitation: SwiftData

SwiftData is not used. Its `@Model` macro plugin is missing from the Command Line Tools, so storage cannot be built or tested here with that framework. History uses SQLite (see Historical metrics). A full Xcode build could use SwiftData, but that would be a new storage layer, not a drop-in change.

## Known limitation: SwiftUI macros in the Command Line Tools

The Command Line Tools do not ship the SwiftUI macro plugin, so the `@State` property wrapper cannot be expanded there. For that reason the UI module uses no property wrappers. Views take presentation values and action closures, and the model holds the expanded state. The app target still uses `@State` for its model, so its full build needs Xcode.

## Build and launch the menu bar app (full Xcode)

The app target needs Xcode because SwiftUI's `@State` macro plugin ships only with Xcode, not with the Command Line Tools.

1. Open `MacFleet.xcodeproj` in Xcode.
2. Select the `MacFleet` scheme and the `My Mac` destination.
3. Press Run (⌘R), or build from the command line:

   ```sh
   xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build
   ```

4. Launch the built `MacFleet.app` from the `DerivedData` products folder shown in the build log. The app has no Dock icon (`LSUIElement`). Its menu bar item shows the compact statistics. Click it to open the popover, use Show details to expand it, then use Refresh or Quit.

The menu bar label starts a sampling loop that refreshes every two seconds. Opening the popover or pressing Refresh also samples.

Not verified in this environment: the Xcode build, the app launch, the menu bar sampling loop, the popover layout, the charts' appearance, light and dark mode in a running app, the Disks and Network sections, the Sources toggles, the Processes window (its opening, layout, and sampling stopping when it closes), and the Alert Settings window, its Windows menu, and notifications appearing on screen. The views and previews typecheck as a module, and the app entry point typechecks with `@State` replaced by a plain property. Nothing was rendered.

## Run the agent

With full Xcode:

```sh
swift run macfleet-agent
```

Without SwiftPM, the verified script builds the agent at `.agent-local/swiftc-build/macfleet-agent`. The agent takes two samples two seconds apart so CPU and network rates are available, prints one JSON snapshot to standard output, and exits. Exit status is 1 with a message on standard error if the load average cannot be read. The snapshot measures every volume and interface, including loopback.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` before signing for distribution.
- The app is ad-hoc signed for local runs (`CODE_SIGN_IDENTITY = "-"`). No team is configured.
- The menu bar icon is an SF Symbol (`server.rack`) rather than a custom asset.
- Snapshots are local to this Mac. The remote protocol is implemented as a library in `MacFleetKit`, but no app or agent entry point uses it yet. `FleetWireFormat` still defines the agent's JSON payload.
- Memory now uses the binary formatter everywhere, so a memory total shows as "16 GB". The earlier popover used the system memory style, which can differ slightly.
- Usage is shown as Elevated from 75% and Critical from 90%, for CPU, memory, and disks alike. Pressure maps warning to elevated and critical to critical.
- Not included: interface MAC addresses, IPv6 addresses, wireless details, per-volume I/O throughput, and per-process network use.
- The Xcode project has no test targets. Tests run through `scripts/swiftc-verify.sh` or `swift test`.
- Alert settings live in user defaults under `MacFleet.alertSettings`, not in a file, so they are per user account on this Mac. The alert hysteresis margins and the sustained and cooldown limits are fixed in code and in `AlertRule`.
- The Xcode project file is hand-written. It passes `plutil -lint`, but Xcode has not opened it here.
- Snapshot JSON has gained `cpu`, `memory`, `memoryPressure`, `volumes`, `network`, and `hardware` fields. Payloads from earlier builds without them no longer decode. No deployed consumers existed.
- `snapshot()` changed to `snapshot(selection:)` as the protocol requirement. The no-argument form remains as a convenience, so existing call sites are unchanged.
