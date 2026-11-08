# MacFleet: project boundaries and working agreement

- Work only in `/Users/mk-rune/test_projects/05-macfleet`. This is one of fourteen independent repositories.
- Do not read, modify, clean up, or run commands in sibling repositories or the user's configuration.
- Work autonomously: choose sensible defaults and document assumptions; do not ask questions or delegate.
- Never install anything globally or use sudo, Homebrew, launchd, host credentials, or host Docker sockets.
- Dependencies, toolchains, caches, browser binaries, SDKs, temporary files and test data stay in this repository. Preserve the supplied project-local environment. Python packages go in `.venv`.
- `.agent-local/` is ignored, project-local build/runtime state. `.opencode/` is managed orchestration configuration; do not change or remove it or bypass the sandbox.
- Use existing system tools read-only, or install pinned tools under this repository. Do not change shell profiles, user settings, Keychain, or global Git settings.
- Bind test servers to loopback; use ports 21400–21499. Limit build/test workers to two unless a required benchmark explicitly needs more.
- Docker-dependent integration tests must remain reproducible but be reported as unverified here if they require access outside this repository. Do not bypass this boundary.
- Do not touch attached hardware, enroll services, flash firmware, install agents, or alter OS settings. Supply manual checklists for such steps.
- Implement only the current numbered prompt, preserving prior behavior. Run appropriate checks, fix failures, and report genuine limitations without fabricating test or benchmark results.
- Before finishing every numbered turn: stop its servers/watchers, remove scratch outputs, update relevant documentation, and make a local conventional-commit Git commit. Do not push.
- End each turn with a short summary of changes, checks actually run, remaining limitations, and commit hash. The orchestrator will provide the next prompt only after this turn ends.

Extend this file with the project's language-specific architecture and verification commands while retaining these boundaries.

## Swift architecture

- Targets macOS 14+ with Swift 6 language mode and SwiftUI. Use only documented public Apple APIs.
- `Package.swift` defines the shared libraries: `MacFleetKit` (models, metrics, storage, networking), `MacFleetState` (application state), `MacFleetUI` (SwiftUI views), the `macfleet-agent` command-line target, and the test targets.
- `MacFleet.xcodeproj` at the repository root hosts the menu bar app (`App/MacFleetApp.swift`) and links the local package. Debug and Release configurations are both defined.
- Keep modules layered: `MacFleetKit` must not import `MacFleetState` or `MacFleetUI`; UI code must not talk to metric APIs directly.

## Swift engineering rules

- Concurrency: use Swift 6 strict concurrency. Mark UI-facing state `@MainActor`. Use `actor` for shared mutable storage. Make values crossing isolation boundaries `Sendable`. Do not use `@unchecked Sendable` or `nonisolated(unsafe)` without a written justification.
- Testability: depend on protocols (`SystemMetricsProviding`, `SnapshotStoring`) and inject them. Provide mock implementations for tests and previews. Never call real system APIs from application state.
- Preservation: when changing behavior, keep existing public APIs and tests passing unless a change is explicitly requested. Add tests for new behavior.
- Resource cleanup: bound in-memory collections, cancel or await asynchronous work that the UI started, and avoid timers or observers that outlive their owner.
- Unavailable data: model it explicitly with `MetricReading` and a `MetricIssue`. Never report 0 for a value that could not be read, and keep failures independent across metrics.
- Counters: derive rates from deltas between samples. Use wrapping arithmetic for 32-bit kernel counters and treat backwards jumps as resets. Kernel CPU ticks arrive in roughly one-second batches, so a short window can be empty; keep the baseline in that case instead of advancing it.
- Presentation: build display values (text, spoken wording, usage levels, chart data) in `MacFleetState/Presentation`, once per sample. Views in `MacFleetUI` take presentation values and action closures only. Keep them free of collection logic.
- UI state: no property wrappers in `MacFleetUI`. The Command Line Tools cannot expand the SwiftUI macro plugin, so hold view state (such as the expanded popover) in the observable model.
- Charts: keep histories bounded, store unavailable samples as gaps rather than zeros, and mark every chart with a spoken summary.
- Verification reporting: report exactly which commands ran and their results. If Xcode or the Swift toolchain cannot run in the environment, say so and list what was not verified. Never claim a build or test passed without running it.

## Verification commands

Run from the repository root.

- Verified in the restricted sandbox: `scripts/swiftc-verify.sh` (manifest, modules, UI typecheck, agent run, Swift Testing suites).
- Dashboard work per sample, optimized build: `scripts/swiftc-benchmark.sh`.
- Expected on full Xcode, not verified here: `swift test`, `swift run macfleet-agent`, `xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build`.
- SwiftPM's build service fails here with EPERM on atomic writes. Do not treat that as a source error. See `README.md`.
