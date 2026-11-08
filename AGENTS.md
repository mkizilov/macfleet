# MacFleet: project boundaries and working rules

## Boundaries

- Work only in this repository. Do not read, modify, clean up, or run commands in other repositories or in the user's
  configuration.
- Do not install anything globally, and do not use sudo, Homebrew, host credentials, host Docker sockets, or launchd to
  install or start services.
- Keep dependencies, toolchains, caches, SDK copies, temporary files, and test data inside this repository. Preserve the
  project-local environment that is supplied. Python packages go in `.venv`.
- `.agent-local/` is git-ignored, project-local build and runtime state. Remove the scratch you create there when you finish.
- `.opencode/` is managed tool configuration. Do not change or remove it, and do not bypass the sandbox it sets up.
- Use existing system tools read-only, or install pinned tools inside the repository. Do not change shell profiles, user
  settings, the Keychain, or global Git settings.
- Bind test servers to loopback, on ports 21400–21499. Limit build and test workers to two, unless a benchmark needs more.
- Docker-dependent integration tests must stay reproducible. Report them as unverified here if they need access outside
  this repository.
- Do not touch attached hardware, enroll or start services, flash firmware, install agents, or alter OS settings. Give a
  manual checklist for those steps instead.

## Working rules

- Decide ambiguous points with the simplest reasonable default, and record the assumption in the relevant document.
- Implement the requested change, preserve prior behaviour, and run the checks that apply. Fix failures. Do not weaken a
  test to make it pass.
- Report exactly which commands ran and what they returned. Report what could not run, and why. Never claim a build or test
  passed without running it. Never fabricate a test or benchmark result.
- Keep the documentation accurate. [docs/verification.md](docs/verification.md) is the status map. Mark each claim as
  implemented, verified, partial, or unverified.
- Before finishing a change: stop any server, watcher, or process you started, remove the scratch files you created, update
  the documents it affects, and make a local conventional-commit Git commit. Do not push. Do not amend, squash, or rebase
  earlier commits.
- End with a short report: what changed, the checks that ran and their results, the limitations, and the commit hash.

## Swift architecture

- Targets macOS 14 or later, with Swift 6 language mode and SwiftUI. Use only documented public Apple APIs.
- `Package.swift` defines `MacFleetKit` (models, metrics, storage, history, networking, the remote protocol, the headless
  agent core, and preferences), `MacFleetState` (application state), `MacFleetUI` (SwiftUI views), the `macfleet-agent`
  command-line target, the `macfleet-headless` agent with TLS and authenticated remote metrics, and the test targets.
- `MacFleet.xcodeproj` at the repository root hosts the menu bar app: `App/MacFleetApp.swift` and
  `App/MacFleetAppDelegate.swift`. Debug and Release configurations are both defined. Xcode has not opened the project in
  this environment.
- Keep the modules layered. `MacFleetKit` must not import `MacFleetState` or `MacFleetUI`. UI code must not call metric APIs
  directly.
- Version metadata lives in `Config/Version.xcconfig`. The Xcode project, `MacFleetVersion`, and the packaging scripts must
  agree with it, and `scripts/check-release.sh` and the release tests enforce that.
- Signing defaults are in `Config/Signing.xcconfig`. A Developer ID or notary profile is never committed. Put a local
  override in `Config/Signing.local.xcconfig`, which is git-ignored.

## Swift engineering rules

- Concurrency: use Swift 6 strict concurrency. Mark UI-facing state `@MainActor`. Use `actor` for shared mutable storage.
  Make values that cross isolation boundaries `Sendable`. Do not use `@unchecked Sendable` or `nonisolated(unsafe)` without
  a written justification in the code.
- Testability: depend on protocols (`SystemMetricsProviding`, `SnapshotStoring`) and inject them. Provide mock
  implementations for tests and previews. Never call real system APIs from application state. Tests never write to the
  real Keychain, and they never change the user's login items.
- Preservation: when behaviour changes, keep public APIs and existing tests passing unless the change is explicitly
  requested. Add tests for new behaviour.
- Resource cleanup: bound in-memory collections. Cancel or await asynchronous work that the UI started. Do not keep timers
  or observers that outlive their owner.
- Unavailable data: model it explicitly with `MetricReading` and a `MetricIssue`. Never report zero for a value that could
  not be read. Keep failures independent across metrics.
- Counters: derive rates from deltas between samples. Use wrapping arithmetic for 32-bit kernel counters, and treat backward
  jumps as resets. Kernel CPU ticks arrive in roughly one-second batches, so a short window can be empty. Keep the baseline
  in that case instead of advancing it.
- Presentation: build display values (text, spoken wording, usage levels, chart data) in `MacFleetState/Presentation`, once
  per sample. Views in `MacFleetUI` take presentation values and action closures only, and hold no collection logic.
- UI state: `MacFleetUI` uses no property wrappers. The Command Line Tools cannot expand the SwiftUI `@State` macro, so view
  state lives in the observable model.
- Charts: keep histories bounded. Store unavailable samples as gaps, not zeros. Mark every chart with a spoken summary.
- Hardware: read only documented public APIs (Metal, `ProcessInfo`, and the other public APIs already in use). Do not add
  IORegistry performance keys, SMC keys, or powermetrics-based readings. Gate every hardware read on its declared capability
  (supported, permission-restricted, or unavailable). Show the reason for a missing measurement, never a zero.
- History: persist through `MetricHistoryStore` only. It is an actor, and its SQLite handle never leaves it. Each write is
  one transaction, and rollup runs before pruning. Keep retention minimums in step with the chart windows. Report a damaged
  file by moving it aside, never by deleting it. Check the store with `scripts/swiftc-history-check.sh` after any change
  to it.
- Sampling: all collection goes through `SamplingEngine`. Keep at most one collection in flight. Never wait on a provider
  without a deadline, and never let a deadline wait on the provider. Race the two through a gate, as `raceAgainstDeadline`
  does. A subscription lasts as long as its stream, so tests must keep the `Subscription` alive while they expect updates.
- Remote protocol: the wire format is versioned. Change it only with a new version and updated fixtures
  (`scripts/update-protocol-fixtures.sh`), and review the fixture diff. Never send metrics to an unauthenticated peer.
- Releases: no signing identity, notary profile, key, or certificate is committed. `dist/` is git-ignored. Packaging is
  reproducible from the scripts, and a notarized build is made only with the user's credentials.

## Verification commands

Run from the repository root. [docs/verification.md](docs/verification.md) lists what each one verifies and what it does not.

- Build, typecheck, run the agent, and run every Swift Testing suite: `sh scripts/swiftc-verify.sh`.
- Release files (syntax, property lists, version agreement; builds nothing): `sh scripts/check-release.sh`.
- Optimized dashboard benchmark: `sh scripts/swiftc-benchmark.sh`.
- Storage crash checks and the seven-day storage benchmark: `sh scripts/swiftc-history-check.sh`.
- Performance budgets, failing on any regression: `sh scripts/performance-check.sh`.
- Release packages, signed and checksummed in `dist/`: `sh scripts/package-app.sh`.
- Notarization, only with a Developer ID build and a notarytool profile: `sh scripts/notarize.sh`.
- Protocol fixtures, only when a wire change is intended: `sh scripts/update-protocol-fixtures.sh`.
- Install or remove the headless agent, planning first: `sh scripts/install-agent.sh` and `sh scripts/uninstall-agent.sh`.
  Both write nothing without `--apply`, and nothing loads without `--load`.
- Expected with full Xcode, not verified in this environment: `swift test`, `swift run macfleet-agent`, and
  `xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build`.
- SwiftPM's build service fails in this sandbox on atomic writes, and its manifest sandbox refuses to nest. Do not treat
  that as a source error. See [docs/verification.md](docs/verification.md).

## Where things are

- [README.md](README.md): the layout, what each part does, and the verified commands.
- [docs/verification.md](docs/verification.md): the status of every area.
- [ROADMAP.md](ROADMAP.md): prioritized future work, with scope, dependencies, acceptance criteria, and effort.
- [docs/installation.md](docs/installation.md), [docs/troubleshooting.md](docs/troubleshooting.md), and
  [docs/distribution.md](docs/distribution.md): installing, common problems, and releasing.
