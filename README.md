# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. Its popover shows live CPU, memory, memory pressure, and uptime for the local Mac. A separate command-line agent prints the same snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`), for building and running the app bundle

## Layout

| Path | Purpose |
| --- | --- |
| `Package.swift` | Shared Swift package: `MacFleetKit`, `MacFleetState`, `MacFleetUI`, `macfleet-agent`, and tests |
| `Sources/MacFleetKit/Models` | `SystemSnapshot`, `MetricReading` (value or explicit unavailable reason), `MetricIssue` |
| `Sources/MacFleetKit/Metrics` | CPU and memory calculations, Mach host counter source, metric providers, mocks |
| `Sources/MacFleetKit/Storage` | Bounded in-memory snapshot store |
| `Sources/MacFleetKit/Networking` | Wire format for snapshots (no transport yet) |
| `Sources/MacFleetState` | Application state (`FleetStatusModel`) and the sampling loop |
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
| Uptime and load average | `ProcessInfo.systemUptime`, `getloadavg` | As before |

CPU counters are cumulative, so percentages come from deltas between samples. Counters are 32-bit and wrap; deltas use wrapping arithmetic. A backwards move that is not a wrap is reported as a counter reset, and the next sample recovers.

CPU needs two samples at least one second apart. The first reading reports "Waiting for a second sample". A reading requested sooner than one second after the previous accepted sample repeats the last result instead of computing a noisy short-window percentage.

Every metric is a `MetricReading`. When a read fails, the UI shows the reason rather than 0. Failures are isolated: a failed memory read does not hide CPU, and a failed per-core read keeps the total.

The menu bar app samples every two seconds. The Refresh button and opening the popover also trigger a sample.

Note on the pressure sysctl: `kern.memorystatus_vm_pressure_level` is a stable, read-only value used by Apple's `memory_pressure` tool, but it is not in the public documentation. If that is unacceptable, the documented alternative is `DispatchSource.makeMemoryPressureSource`, which reports only transitions and needs a running listener.

## Verified commands

Run from the repository root.

```sh
scripts/swiftc-verify.sh
```

This script typechecks the manifest, builds `MacFleetKit` and `MacFleetState` as dylibs, typechecks `MacFleetUI`, builds and runs `macfleet-agent`, then compiles and runs the Swift Testing suites. It exits non-zero on the first failure. Outputs go to `.agent-local/swiftc-build/`, which is git-ignored. Remove it with `rm -rf .agent-local/swiftc-build`.

The script uses the Command Line Tools SDK by default. Override with `DEV=/path/to/Developer` or `SDK=/path/to/MacOSX.sdk`.

Last run result: manifest, all modules, UI typecheck, and the agent passed. All 43 Swift Testing tests in 11 suites passed. That includes 3 live tests that call the real Mach APIs on this Mac.

## Accuracy check against system tools

Taken on the development Mac (arm64, 10 logical CPUs, 16 GB, macOS 27.2 build 26B123):

- CPU: agent total 10.5%. `iostat -c 2 -w 2` over a 2-second interval reported 6% user + 4% system = 10% busy. The agent's per-core mean (10.5%) matches its total.
- Memory: agent used 11.65 GB. `vm_stat` anonymous, purgeable, wired, and compressor page counts give about 11.67 GB. The small difference is from counts changing between the two reads.
- Pressure: agent reported 1 (normal). The agent reads the same sysctl that `memory_pressure` uses, so this is not an independent cross-check.

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

Not verified in this environment: the Xcode build, the app launch, the menu bar sampling loop, and the popover layout. Only a copy of `App/MacFleetApp.swift` with `@State` replaced by `let` typechecked here, and it typechecked.

## Run the agent

With full Xcode:

```sh
swift run macfleet-agent
```

Without SwiftPM, the verified script builds the agent at `.agent-local/swiftc-build/macfleet-agent`. The agent takes two samples two seconds apart so CPU utilization is available, prints one JSON snapshot to standard output, and exits. Exit status is 1 with a message on standard error if the load average cannot be read.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` before signing for distribution.
- The app is ad-hoc signed for local runs (`CODE_SIGN_IDENTITY = "-"`). No team is configured.
- The menu bar icon uses an SF Symbol rather than a custom asset.
- Snapshots are local to this Mac. Networking transport is not implemented; `FleetWireFormat` only defines the payload.
- The Xcode project has no test targets. Tests run through `scripts/swiftc-verify.sh` or `swift test`.
- The Xcode project file is hand-written. It passes `plutil -lint`, but Xcode has not opened it here.
- Snapshot JSON gained `cpu`, `memory`, and `memoryPressure` fields. Payloads from the earlier build without them no longer decode. No deployed consumers existed.
