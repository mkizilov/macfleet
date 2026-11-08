# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. Its popover shows live CPU, memory, memory pressure, disk, network, and uptime figures for the local Mac. A separate command-line agent prints the same snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`), for building and running the app bundle

## Layout

| Path | Purpose |
| --- | --- |
| `Package.swift` | Shared Swift package: `MacFleetKit`, `MacFleetState`, `MacFleetUI`, `macfleet-agent`, and tests |
| `Sources/MacFleetKit/Models` | `SystemSnapshot`, `MetricReading` (value or explicit unavailable reason), `MetricIssue`, `MonitoringSelection`, byte and percent formatting |
| `Sources/MacFleetKit/Metrics` | CPU, memory, storage, and network calculations; Mach, FileManager, and getifaddrs/sysctl sources; metric providers; mocks |
| `Sources/MacFleetKit/Storage` | Bounded in-memory snapshot store |
| `Sources/MacFleetKit/Networking` | Wire format for snapshots (no transport yet) |
| `Sources/MacFleetState` | Application state (`FleetStatusModel`), the sampling loop, and monitoring selection |
| `Sources/MacFleetUI` | SwiftUI popover view |
| `Sources/MacFleetAgent` | Command-line agent target |
| `App/MacFleetApp.swift` | Menu bar app entry point (`MenuBarExtra`) |
| `MacFleet.xcodeproj` | Xcode application project with Debug and Release configurations |
| `Tests/` | Swift Testing suites for the kit and the state layer |
| `scripts/swiftc-verify.sh` | Verified build, test, and agent-run pipeline using `swiftc` only |
| `scripts/swiftc-test-runner/main.swift` | Entry point that runs the Swift Testing suites from the script |

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
- **Disk and network units are decimal (KB = 1,000 bytes), like Finder.** Memory keeps its earlier binary display, so the popover can show memory in one unit and disks in another.
- **Available disk space uses "important usage".** It includes purgeable space, as Finder does. `df` leaves purgeable space out, so its figure is lower.

### Monitoring selection

Discovery always lists every mounted volume and network interface. `MonitoringSelection` decides which ones are measured:

- Loopback (`lo0`) is excluded by default, because its traffic never crosses a network link.
- Individual volumes and interfaces can be turned off and on from the "Monitored sources" disclosure in the popover. Changing a toggle refreshes immediately.
- An excluded item stays in the snapshot with `.notMonitored` and no capacity or rate. Turning it back on starts its baseline over, so its first rate reads "Waiting for a second sample".
- The selection lives in `FleetStatusModel` for the session. It is not saved between launches.
- The `snapshot()` convenience uses `MonitoringSelection.default`. Use `snapshot(selection: .all)` to measure everything, including loopback.

The popover's Disks section lists browsable monitored volumes. The Network section lists monitored interfaces that have an IPv4 address or have carried traffic, so idle virtual interfaces stay out of the summary. Hidden items remain in the sources list.

### Handling failures

| Situation | Behavior |
| --- | --- |
| A volume disappears between listing and reading | Reported as `volumeDisconnected`. It drops out of the next listing |
| A volume refuses resource reads | Still listed, with `permissionDenied` or `readFailed` on its capacity |
| A volume reports inconsistent capacity | `inconsistentStorageCounters`. Available above total, or zero total |
| Mounted volume list unavailable | Volumes reported as `notProvided`. CPU, memory, and network are unaffected |
| An interface is disconnected | Still listed, marked "(down)" in the popover, with a zero rate |
| An interface is removed | Dropped from the listing and its baseline discarded |
| An interface has no byte counters | Listed with `notProvided` on its totals and rates |
| Counters move backwards | `counterReset` for that interval; the next interval recovers |
| Interface list unavailable | Network reported with the `getifaddrs` or `sysctl` failure |

Neither `getifaddrs`, `sysctl(NET_RT_IFLIST2)`, nor `FileManager` volume properties need special permissions. The permission and disconnect paths are covered by unit tests with injected failures rather than by revoking real permissions.

## Verified commands

Run from the repository root.

```sh
scripts/swiftc-verify.sh
```

This script typechecks the manifest, builds `MacFleetKit` and `MacFleetState` as dylibs, typechecks `MacFleetUI`, builds and runs `macfleet-agent`, then compiles and runs the Swift Testing suites. It exits non-zero on the first failure. Outputs go to `.agent-local/swiftc-build/`, which is git-ignored. Remove it with `rm -rf .agent-local/swiftc-build`.

The script uses the Command Line Tools SDK by default. Override with `DEV=/path/to/Developer` or `SDK=/path/to/MacOSX.sdk`.

Last run result: manifest, all modules, UI typecheck, and the agent passed with no compiler warnings. All 97 Swift Testing tests in 22 suites passed, including live tests that call the real Mach, FileManager, and getifaddrs/sysctl APIs on this Mac. The full pipeline passed three consecutive runs after one flaky live-CPU failure was traced to the batched kernel counters described above.

The test suites cover:

- Utilization and rate calculations: busy share, nice ticks, rollover from 2³² to 0, resets, zero elapsed ticks or time, core-count changes, and per-core failures.
- Trackers: first sample, minimum window, empty windows that keep the baseline, interfaces appearing and disappearing, and counter resets that recover.
- Disk capacity: utilization, zero total, available above total, and missing values.
- Byte and percent formatting: unit boundaries, rounding up to the next unit, rates, and percentages.
- Failure mapping for volume resource errors: permission denied, missing file, and other errors.
- Provider behavior with scripted sources and a manual clock, so rates are exact: failures isolated per metric, exclusions, and volumes that stay listed when a read is denied.
- The monitoring selection, its JSON round trip, and the model's toggles.
- The sampling loop, which stops when cancelled.

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

## Build and launch the menu bar app (full Xcode)

The app target needs Xcode because SwiftUI's `@State` macro plugin ships only with Xcode, not with the Command Line Tools.

1. Open `MacFleet.xcodeproj` in Xcode.
2. Select the `MacFleet` scheme and the `My Mac` destination.
3. Press Run (⌘R), or build from the command line:

   ```sh
   xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build
   ```

4. Launch the built `MacFleet.app` from the `DerivedData` products folder shown in the build log. The app has no Dock icon (`LSUIElement`). Its icon, a server-rack SF Symbol, appears in the menu bar. Click it to open the popover, then use Refresh or Quit.

The menu bar label starts a sampling loop that refreshes every two seconds. Opening the popover or pressing Refresh also samples.

Not verified in this environment: the Xcode build, the app launch, the menu bar sampling loop, the popover layout, the Disks and Network sections, and the Sources toggles. Only a copy of `App/MacFleetApp.swift` with `@State` replaced by `let` typechecked here, and the popover and its section views typechecked as a module.

## Run the agent

With full Xcode:

```sh
swift run macfleet-agent
```

Without SwiftPM, the verified script builds the agent at `.agent-local/swiftc-build/macfleet-agent`. The agent takes two samples two seconds apart so CPU and network rates are available, prints one JSON snapshot to standard output, and exits. Exit status is 1 with a message on standard error if the load average cannot be read. The snapshot measures every volume and interface, including loopback.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` before signing for distribution.
- The app is ad-hoc signed for local runs (`CODE_SIGN_IDENTITY = "-"`). No team is configured.
- The menu bar icon uses an SF Symbol rather than a custom asset.
- Snapshots are local to this Mac. Networking transport is not implemented; `FleetWireFormat` only defines the payload.
- Not included: interface MAC addresses, IPv6 addresses, wireless details, per-volume I/O throughput, and per-process network use.
- The Xcode project has no test targets. Tests run through `scripts/swiftc-verify.sh` or `swift test`.
- The Xcode project file is hand-written. It passes `plutil -lint`, but Xcode has not opened it here.
- Snapshot JSON has gained `cpu`, `memory`, `memoryPressure`, `volumes`, and `network` fields. Payloads from earlier builds without them no longer decode. No deployed consumers existed.
- `snapshot()` changed to `snapshot(selection:)` as the protocol requirement. The no-argument form remains as a convenience, so existing call sites are unchanged.
