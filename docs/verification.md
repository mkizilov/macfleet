# Verification status

This page says what MacFleet does, what has been checked, and what has not. Each row names the check, so a claim can be
re-run. The status words mean:

- **Implemented.** The code exists and is wired into the app, the agent, or a script.
- **Verified.** An automated check ran in this environment and passed.
- **Partial.** Part of the behaviour is verified, and the rest is listed.
- **Unverified.** The code exists and compiles, but no check has exercised it in this environment.
- **Not implemented.** There is no code for it.

The results below come from the release review of the current tree (727 tests in 154 suites, the performance check, and the
packaging run on this Mac, macOS 27.2, Swift 6.4.2, Command Line Tools). Nothing here was run on a second Mac or on
GitHub.

## Commands

| Command | What it checks | Last result |
| --- | --- | --- |
| `sh scripts/swiftc-verify.sh` | Manifest, every module, the UI typecheck, the agent, the headless smoke check, and every Swift Testing suite | Passed, 727 tests in 154 suites, zero warnings, zero errors |
| `sh scripts/check-release.sh` | Shell syntax, property lists, and version agreement across `Config/`, the Xcode project, and the Swift constants | Passed |
| `sh scripts/performance-check.sh` | Optimized benchmarks against `Config/performance-budgets.env` | Passed, every budget within its ceiling |
| `sh scripts/swiftc-benchmark.sh` | Dashboard work per sample, optimized, two runs | Median 45.0 and 44.0 µs |
| `sh scripts/swiftc-history-check.sh` | Crash trials for batches, upkeep, and torn writes, and the seven-day storage benchmark | Not run in this review. It passed when the history code last changed, and that code is unchanged since |
| `sh scripts/package-app.sh` | Release packages in `dist/`, signed and checksummed | Passed. Both checksums verify. The packaged agent reports the version in `Config/Version.xcconfig` |
| `sh scripts/notarize.sh` | Notarization of a Developer ID package | Refuses an ad hoc build and a missing profile, as tested. No notarization was submitted |
| `sh scripts/install-agent.sh` and `scripts/uninstall-agent.sh` | Plan-first install and removal of the agent | Passed in a scratch folder, from a packaged build. No LaunchAgent was loaded |
| `sh scripts/update-protocol-fixtures.sh` | Regenerates the protocol 1.0 fixtures | Run only when a wire change is intended. Its output is compared by the tests |
| `swift build --disable-sandbox` | SwiftPM manifest and package graph | The manifest compiles and the package graph loads. The build then stops in the build service (see below) |
| `xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build` | The Xcode application project | Not run. Xcode is not installed here |

## Areas

| Area | Status | Verified by | Not verified |
| --- | --- | --- | --- |
| CPU, memory, storage, network, thermal, GPU readings | Implemented | Unit and live tests in `swiftc-verify.sh`; a comparison with `iostat`, `vm_stat`, `df`, and `netstat` in the README | Other Mac models, and capability gating on hardware other than this Mac |
| Menu bar: choice of metrics, startup disk, icon alone | Implemented | Presentation and model tests (`SettingsMenuBarAndRateFlowTests`, menu bar label tests) | The rendered label in a running app |
| Popover and details view | Implemented | Presentation tests; app target typecheck | Layout, charts, and light and dark mode on screen |
| Processes window | Implemented | Aggregation, sorting, search, the monitor, and a live listing of this process | Rendering, sampling stopping on close, a second account's permission boundary |
| Sampling engine and deadlines | Verified | Virtual-time tests and `DeadlineRaceTests`, including work that ignores cancellation | Sustained load over hours |
| Local history | Verified | Tests, the storage gate (crash trials, torn writes), and benchmarks | Real power loss, and months of real use |
| Multi-Mac history and CSV export | Partial | Host isolation, clock cases, rollup, retention, concurrent writers, and export tests. The fleet benchmark uses simulated readings | Real clock skew between Macs, the export save panel, and the History window on screen |
| Alerts and notification thresholds | Partial | Engine, cooldown, hysteresis, permission model, and posting with a recording notifier | Notification delivery and banners, and the permission prompt, in a signed app |
| Settings: rates, menu bar, persistence, damaged data | Partial | Model tests, persistence round trips, and damaged-data tests | The Settings window on screen |
| Launch at login | Partial | State mapping for each status, through `MemoryLaunchAtLogin` | `SMAppService` registration, approval, and login start from an installed app |
| Keyboard navigation and commands | Partial | The command table: unique keys, no `⌘,` clash, and each command's destination | Key presses in a running app, focus order, and focus rings |
| Accessibility of charts and controls | Partial | Spoken summaries, labels, and the dashed upload line, through presentation tests | VoiceOver, Dynamic Type, Increase Contrast, Reduce Motion, and Accessibility Inspector |
| UI automation tests | Not implemented | Model-level flow tests stand in for them | An XCUITest target, which needs Xcode |
| Fleet window: pairing, trust, reconnect, groups | Partial | State tests with a manual clock, loopback TLS integration tests, and presentation tests | Layout and confirmation sheet on screen, real networks, sleep and wake, long runs |
| Remote protocol 1.0 | Partial | Encoding, framing, negotiation, authentication, loopback sessions, and byte-for-byte fixtures | A real tailnet, an independent implementation, and any version after 1.0 |
| Pinned TLS identity | Partial | Probe, pin match and mismatch, changed certificate, and an expired certificate on loopback | RSA only. EC identities did not import in testing. Expiry during a session and warnings before expiry |
| Keychain secret storage (app and agent) | Unverified | The store compiles. Tests use an in-memory store and the file store | Reading and writing the real keychain. The tests do not change it, as the project rules require |
| Headless agent: run, health, shutdown | Verified | The in-process integration tests and `headless-smoke.sh`, which starts the real binary and takes two snapshots over TLS | A launchd service, and binding to a Tailscale address |
| Headless agent: install and uninstall scripts | Verified | `AgentInstallScriptTests` in a scratch folder, and an end-to-end run from a built package | Loading under `launchctl`, and login start |
| Failed-authentication rate limiting | Not implemented | Failed attempts are logged with no secret | Any limit. A peer can attempt as often as it likes |
| Release versioning and metadata | Verified | `ReleaseMetadataTests` and `check-release.sh` | Xcode's own build settings |
| Ad hoc signing and the hardened runtime | Verified | `package-app.sh` signs and checks the signature. The signing report shows the runtime flag | A Developer ID signature |
| Notarization and Gatekeeper | Unverified | The guard refuses an ad hoc build. The script is written | Any real notarization, staple, or `spctl` assessment |
| Packaged app launch | Partial | The packaged app ran for four seconds without a library-loading error (checked again in this review) | Its windows, menu bar, and behaviour over time |
| CI workflow | Unverified | The YAML parses, every referenced script exists, and `ReleaseMetadataTests` guard the runner and toolchain | A run on GitHub |
| Performance budgets | Partial | `performance-check.sh`: dashboard work, history save, queries, fleet ingest, history memory growth, reopen | Resident memory of a running app or agent, and rendering |
| Energy (wakeups, CPU of the running app) | Unverified | The sampling policy and its limits are tested | Instruments measurements of wakeups and CPU |

## Toolchain limits

- **SwiftPM in this sandbox.** SwiftPM runs each manifest inside its own `sandbox-exec`, and this sandbox refuses to nest
  one. `--disable-sandbox` turns off that inner sandbox only. The build service then fails on an atomic write to
  `XCBuildData`, which is the documented sandbox limit. `swift test` has not run here.
- **SwiftUI macros.** The Command Line Tools cannot expand `@State`. The UI module therefore uses no property wrappers, and
  the app target uses none either.
- **Xcode.** Xcode is not installed in this environment, so the Xcode project has never been opened or built here.
- **Toolchain paths.** The scripts use `/Library/Developer/CommandLineTools` by default. CI pins `DEVELOPER_DIR` to that
  path. A Mac with only Xcode needs `DEV` or `SDK` set.
