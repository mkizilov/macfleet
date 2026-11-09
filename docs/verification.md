# Verification status

This page says what MacFleet does, what has been checked, and what has not. Each row names the check, so a claim can be
re-run. The status words mean:

- **Implemented.** The code exists and is wired into the app, the agent, or a script.
- **Verified.** An automated check ran in this environment and passed.
- **Partial.** Part of the behaviour is verified, and the rest is listed.
- **Unverified.** The code exists and compiles, but no check has exercised it in this environment.
- **Not implemented.** There is no code for it.

The results below come from the publication review of the current tree: 728 tests in 154 suites, the performance check,
the storage gate, the packaging run, and the publication scans. They were run on this Mac (macOS 27.2, arm64), with the
Command Line Tools and Swift 6.4.4. Nothing here was run on a second Mac, on GitHub, or with Xcode.

## Commands

| Command | What it checks | Last result |
| --- | --- | --- |
| `sh scripts/swiftc-verify.sh` | Manifest, every module, the UI typecheck, the agent, the headless smoke check, and every Swift Testing suite, each under a time limit | Passed, 728 tests in 154 suites, zero warnings, zero errors |
| `sh scripts/check-release.sh` | Shell syntax, property lists, and version agreement across `Config/`, the Xcode project, and the Swift constants | Passed |
| `sh scripts/performance-check.sh` | Optimized benchmarks against `Config/performance-budgets.env` | Passed. Dashboard 44.0 µs, history save 2.9 µs, reopen 7.38 ms, and every other budget within its ceiling |
| `sh scripts/swiftc-benchmark.sh` | Dashboard work per sample, optimized | Run in the release review: median 45.0 and 44.0 µs |
| `sh scripts/swiftc-history-check.sh` | Crash trials for batches, upkeep, and torn writes, and the seven-day storage benchmark | Passed: batches 30 of 30, upkeep 30 of 30, torn writes 5 of 5 |
| `sh scripts/package-app.sh` | Release packages in `dist/`, signed and checksummed, with the license in each | Passed. Both checksums verify. The packaged agent reports the version in `Config/Version.xcconfig` |
| `sh scripts/install-agent.sh` and `scripts/uninstall-agent.sh` | Plan-first install and removal of the agent | Passed in a scratch folder, from a packaged build. No LaunchAgent was loaded |
| `sh scripts/notarize.sh` | Notarization of a Developer ID package | Refuses an ad hoc build and a missing profile, as tested. No notarization was submitted |
| `sh scripts/update-protocol-fixtures.sh` | Regenerates the protocol 1.0 fixtures | Regenerated in this review, and all six files are byte-identical to the committed ones |
| `swift package --disable-sandbox dump-package` | The package manifest, its targets, and the fixture exclusion | Passed: seven targets, and the test target excludes `Fixtures` |
| `swift build --disable-sandbox` (default and `--build-system swiftbuild`) | SwiftPM's build | Not complete. The manifest compiles, and both build systems stop at the build service's `XCBuildData` write (see below) |
| `xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build` | The Xcode application project | Not run. Xcode is not installed in this environment |
| `swift-format lint --strict` with a candidate configuration | Style findings across the sources | Ran: 1,424 findings in 132 files, all style. Not a gate (see Lint below) |
| `gitleaks git` (pinned 8.30.1, checksum-verified, in `.tools/`) | Secrets in every commit | Passed: no leaks in any commit on any ref |

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
| Packaged app launch | Partial | The packaged app ran for four seconds without a library-loading error, checked again in this review | Its windows, menu bar, and behaviour over time |
| Time limits on hanging steps | Verified | A three-second bound stopped the real test binary, and the bounded helper keeps errexit and exit status. The Swift Testing time limit names a blocked test after a minute | A hang inside a real remote peer |
| MIT license | Verified | `LICENSE` matches the Open Source Initiative text after whitespace and quote normalization. A test pins its first line and copyright. The packages carry it | Legal review. The licence choice and the copyright holder are the owner's |
| Third-party software | Verified | No third-party source or dependency in the tracked tree or the history. The packages link only system libraries | An audit of the Apple SDK's own terms, which are not redistributed |
| Publication scan | Verified, with one finding | gitleaks over every commit: no leaks. The current tree has no personal data or key material. There is no remote, and `.opencode/` has never been tracked | One historic commit contains an absolute home-folder path. See Publication checks |
| Lint and formatting | Partial | `swift-format lint` runs with the Command Line Tools' 6.4.4 | No gate. 1,424 style findings in 132 files, none of them a behaviour change |
| CI workflow | Partial | The YAML parses, every referenced script exists, and `ReleaseMetadataTests` guard the runner and toolchain. Hosted run 42554238438 (commit `ab31da4`) passed `Release files`, and its test build failed at `HistoryStoreTests.swift:321` (see Toolchain limits) | Later hosted runs. The performance and package jobs were skipped by that run, so they have not run hosted |
| Performance budgets | Partial | `performance-check.sh`: dashboard work, history save, queries, fleet ingest, history memory growth, reopen | Resident memory of a running app or agent, and rendering |
| Energy (wakeups, CPU of the running app) | Unverified | The sampling policy and its limits are tested | Instruments measurements of wakeups and CPU |

## Publication checks

- **Secrets.** gitleaks 8.30.1 scanned every commit on every ref and found no leaks. The binary came from the project's
  GitHub release, and its checksum was checked against the release's checksum file before it ran. It sits in `.tools/`,
  which is git-ignored.
- **Current tree.** `git grep` finds no personal path, email address, or key material in tracked files. The only
  matches are the copyright line and documentation placeholders such as `/Users/you/`.
- **History.** No blob is over 1 MB. No file with a key or certificate extension was ever tracked. The author identities
  in the history are the workspace's own, and no remote is configured.
- **One finding.** One historic commit, `78c32d5`, contains the absolute home-folder path of the machine it was written
  on, in `AGENTS.md`. The current tree does not contain it. The history has not been rewritten, and that decision is
  left to the owner before publication.

## Toolchain limits

- **Hosted Swift version.** Hosted run 42554238438 failed to compile one `#expect` in `HistoryStoreTests.swift`, with the solver's "unable to type-check this expression in reasonable time" error. The image's macOS 15 runner lists Xcode Command Line Tools 16.4, which bundles Swift 6.1. This sandbox has Swift 6.4.2. The assertion is now split into typed steps, and `swiftc-verify.sh` passes locally. The hosted failure was not reproduced here: the Swift 6.1.2 toolchain could not build against this Mac's SDKs (`could not build Objective-C module '_Builtin_float'`), and a matching macOS 15 SDK comes only with Xcode. Lowering the solver scope threshold on 6.4.2 showed the split form to be cheaper than the original, but not that the hosted failure would recur.
- **SwiftPM in this sandbox.** SwiftPM runs each manifest inside its own `sandbox-exec`, and this sandbox refuses to nest
  one. `--disable-sandbox` turns off that inner sandbox only, and the manifest then compiles. The build service then
  fails on an atomic write to `XCBuildData`, with either build system. This is the sandbox's limit, and it is not in the
  source. `swift test` has not run here.
- **Lint.** The project has no lint gate. The configuration used for the measurement is described in the README.
- **SwiftUI macros.** The Command Line Tools cannot expand `@State`. The UI module therefore uses no property wrappers, and
  the app target uses none either.
- **Xcode.** Xcode is not installed in this environment, so the Xcode project has never been opened or built here. It
  cannot be installed from this sandbox without writing outside the repository.
- **Toolchain paths.** The scripts use `/Library/Developer/CommandLineTools` by default. CI pins `DEVELOPER_DIR` to that
  path. A Mac with only Xcode needs `DEV` or `SDK` set.
- **Network.** GitHub, the GitHub API, PyPI, and Apple's website were all reachable in this review. Tools can be fetched
  into the project's `.tools/` directory.
