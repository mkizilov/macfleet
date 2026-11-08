# MacFleet roadmap

This roadmap follows a release review of the current tree. It lists what is still missing, what is unverified, and what
would be risky to ship. The steps are in priority order. Priority 0 covers security and verification gaps in code that
already exists. Priority 1 covers original requirements that are implemented but not verified in a running app. Priority
2 covers hardening and operations. Priority 3 is optional. Steps 1, 4, and 5 need no Xcode, and step 2 needs only a
logged-in session. Steps 1 and 4 can run in parallel with the others.

[docs/verification.md](docs/verification.md) is the status map that every step refers to. A step is done when its
acceptance criteria are met and that map is updated.

## Review summary

**Publication review.** This pass checked the repository for publication. It covered the license, third-party notices,
secrets and personal data in the tracked tree and in the full history, and the checks that earlier passes could not run.

**Done in this pass.**

- Added the MIT license in `LICENSE`, with the copyright holder named in the app's copyright string. Both packages carry the
  license text.
- Bounded every long step with a time limit: the Swift Testing run, the agent and the smoke check's network steps, the
  benchmarks, and the storage gate's writer children. A three-second bound on the real test binary stopped it, and no process
  was left behind.
- Tightened `.gitignore` for managed tool configuration and key material. No tracked file has those names.
- Rechecked the registry claim. No repository file says the registry is unreachable. GitHub, the GitHub API, PyPI, and Apple's
  site all responded in this pass. gitleaks 8.30.1 was installed into `.tools/` and checked against its release checksums.
- Rechecked the SwiftPM claim. The manifest now compiles with `--disable-sandbox`. Both build systems still stop at the build
  service's `XCBuildData` write.
- Ran swift-format's lint over the sources. It reports 1,424 style findings in 132 files and no behaviour change. The project
  has no lint gate, so the result is reported, not enforced.
- Scanned for secrets and personal data. gitleaks found no leaks in any commit, and the tracked tree is clean. One historic
  commit (`78c32d5`) contains an absolute home-folder path. It is reported, and the history has not been rewritten.

**Fixed in earlier passes.** The protocol-fixture warning, the CI pipe and runner defects, and the stale documentation claims.

**Current state.** MIT-licensed. 728 tests in 154 suites pass with zero warnings and zero errors. The storage gate, the
performance budgets, the packaging, and the installer pass. Most user-facing requirements are implemented but not verified in
a running app. The app has no Developer ID signature and no notarization, and it has not run on a second Mac. The Xcode project
has never been built, and SwiftPM has not built in this sandbox.

**Largest risks, in order:**

1. The app's windows have never been seen running (step 2).
2. Failed-authentication attempts have no rate limit (step 1).
3. The app's keychain path is never exercised by a check (step 4).
4. The Xcode project is hand-written and has never been built (step 3).
5. Notification delivery has not been observed (step 5).
6. The 26 `assumeIsolated` bridges in `App/MacFleetApp.swift` trap if SwiftUI ever calls one off the main actor. Nothing has
   shown that happening, and step 2's Main Thread Checker run tests it.

**Before publication (owner decisions, not roadmap steps).**

- Decide whether to rewrite the historic home-folder path in commit `78c32d5`, or publish the history as it is. The
  repository has not been rewritten.
- Confirm the copyright holder and year in `LICENSE`, the app's copyright string, and the README.
- The commit authors are the workspace's own identities. Confirm that they are the ones to publish.

## Priority 0: security and verification gaps

## 1. Rate-limit failed client authentication

**Scope.** In `RemoteMetricsHost` (`Sources/MacFleetKit/Remote/RemoteHostServer.swift`), count failed client proofs per
source address. After a threshold, refuse new handshakes from that address for a period that doubles on each further
failure, from 1 minute to a 15-minute cap. Keep the table bounded, with least-recently-used eviction at 1,024 addresses.
Log `auth.locked` with the address and the period, never a secret. A successful authentication clears the address's count.

**Rationale.** The threat model says failed attempts are logged but not limited. A 256-bit secret cannot be guessed, but a
peer inside an allowed network can open sessions as fast as it likes. Each attempt costs a TLS handshake, a log record,
and one of the eight session slots, and stalled handshakes hold those slots until their deadline.

**Dependencies.** None. This is Kit-level work with a manual clock.

**Acceptance criteria.**
- With a manual clock, N failures lock an address, and valid clients on other addresses still connect.
- The lock expires, the next lock lasts twice as long, and a success clears the count.
- The table stays within its bound under 10,000 distinct addresses.
- A loopback test shows a locked address refused before any metrics are sent.
- The threat-model row in `docs/remote-protocol.md` and the status row in `docs/verification.md` are updated.

**Effort.** 8 hours.

## 2. Run the app in a real macOS session and record a window checklist

**Scope.** Run the app from `dist/` (the packaged build, which needs no Xcode) in a logged-in session. Walk through the
menu bar label, the popover and its details view, the Fleet, History, Processes, and Settings windows, every Navigate
command and its shortcut, every Settings pane, closing and reopening each window, quitting, and that sampling stops when
the Processes window closes. Run once with Thread Sanitizer and the Main Thread Checker enabled. Use the Xcode debug build
from step 3 when it is available. Otherwise, build the packaged app again with the sanitizer flag. Record each result, with
a screenshot of each window at default and largest text sizes. Screenshots can show private data, so they stay out of the
repository.

**Rationale.** Nothing has been rendered. The layout, the charts, the window routing, and the main-thread behaviour are the
largest unverified areas, and the task asked for window behaviour and responsiveness to be reviewed. The Main Thread
Checker run also tests the `assumeIsolated` bridges.

**Dependencies.** A logged-in graphical session on a Mac the user owns. The packaged app from `scripts/package-app.sh`.
Step 3 is optional here.

**Acceptance criteria.**
- Every item in the checklist has a recorded pass or fail with the observed text.
- Every failure is fixed, or filed here with its reproduction.
- The sanitizer and main-thread runs report no finding, or each finding is fixed or explained.
- `docs/verification.md` and the README status are updated from "unverified" to what was seen.

**Effort.** 12 hours, excluding fixes.

## 3. Open, validate, and build the Xcode project

**Scope.** Open `MacFleet.xcodeproj` in full Xcode 16 or later. Check every file reference, including the app sources and
the package products the app links. Confirm Swift 6 language mode and the 14.0 deployment target. Build Debug and Release
with `xcodebuild`, and fix every warning. Decide whether the project should be generated from `Package.swift` so that it
cannot drift from the source list. Record the decision in `docs/distribution.md`.

**Rationale.** The project file is hand-written and has never been opened by Xcode. The Release configuration has not been
built, and `xcodebuild` is the path that signing and notarization depend on.

**Dependencies.** Full Xcode 16 or later.

**Acceptance criteria.**
- `xcodebuild -configuration Debug build` and `-configuration Release build` both succeed with zero warnings and zero errors.
- `scripts/check-release.sh` still passes.
- The Xcode build behaves like the packaged app in the step 2 checklist.
- The drift decision is recorded.

**Effort.** 8 hours.

## 4. Put the keychain store behind a testable interface and check it on a real keychain

**Scope.** `KeychainSecretStore` (`Sources/MacFleetKit/Agent/AgentSecrets.swift`) calls `SecItemCopyMatching` and
`SecItemAdd` directly. Add a small backend protocol with add, copy, update, and delete. The real backend uses the Security
framework, and tests use a fake. Cover every status path in the store: item not found, duplicate item, interaction not
allowed, and unexpected status. Check that no secret appears in an error message. Then run a manual checklist on a Mac the
user owns: create, read after a relaunch, update, delete, and the unlock prompt. The automated tests must never write to
the real keychain, as the project rules require.

**Rationale.** The app stores every paired Mac's client secret in this store, and no check exercises it. A locked keychain
or a denied prompt is untested.

**Dependencies.** None for the fake-backed tests. The manual checklist needs the user's session.

**Acceptance criteria.**
- The fake-backed tests cover every status path, and each one has an expected user-facing message.
- No error text contains a secret. A test checks this with a known secret.
- The manual checklist results are recorded in `docs/verification.md`.
- No automated test writes to a real keychain.

**Effort.** 12 hours (10 hours of code and tests, 2 hours of manual checks).

## 5. Deliver and verify notifications in the packaged app

**Scope.** With the packaged app, set a CPU threshold low enough to trigger quickly. Check that the first request shows the
permission prompt, and that a banner and a Notification Center entry appear. Check that the cooldown suppresses repeats.
Check that a denied permission shows the status text. Check that a permission changed in System Settings is read again when
the Notifications pane opens. Restore every setting afterwards.

**Rationale.** Notifications are a core requirement of the alerts feature, and delivery has never been observed. The app
bundle has to be signed and carry its identifier for the system to deliver them.

**Dependencies.** Step 2.

**Acceptance criteria.**
- Each of the five outcomes above is recorded as observed.
- Each failure is fixed, or filed here.
- The alerts row in `docs/verification.md` is updated.

**Effort.** 4 hours.

## Priority 1: original requirements and distribution

## 6. Sign with a Developer ID, notarize, and decide the sandbox

**Scope.** Use a Developer ID Application certificate, supplied by the user through `MACFLEET_SIGN_IDENTITY` or
`Config/Signing.local.xcconfig`. Package with `scripts/package-app.sh` and a secure timestamp. Submit with
`scripts/notarize.sh` and a notarytool keychain profile the user creates. Staple the ticket, run `spctl --assess`, and open
the app on a second Mac. Settle the bundle identifier, and update `MACFLEET_BUNDLE_ID` in `Config/Version.xcconfig` and the
Xcode project together. Decide whether to enable App Sandbox. If so, add `com.apple.security.network.client`, check
keychain access and the history file's location inside the container, and repeat step 2 in the sandbox. Record the
decision in `docs/distribution.md`.

**Rationale.** The current build is ad hoc and runs only on the Mac that built it. Distribution needs a notarized build, and
the sandbox decision changes what the app can reach.

**Dependencies.** An Apple Developer Program membership and a certificate, supplied by the user. Steps 2 and 3.

**Acceptance criteria.**
- `spctl --assess --type execute` accepts the stapled app.
- The app opens on a second Mac without a Gatekeeper warning.
- `scripts/check-release.sh` passes with the final identifier.
- Checksums are published with the release notes.
- The sandbox decision is recorded, and the sandboxed app passes step 2 if the sandbox is on.

**Effort.** 10 hours, excluding Apple's processing time.

## 7. Pair and reconnect across a real tailnet

**Scope.** Use two Macs on one tailnet, with the user's explicit approval to install the agent on the second Mac. Install the
agent with `scripts/install-agent.sh --apply --load`, bound to its Tailscale address. Pair it from the app on the first Mac:
Check Identity, compare the fingerprint over a channel the user trusts, then Trust and Save. Exercise these events and record
the reconnect time for each: restarting the agent, disconnecting and reconnecting Tailscale, sleeping and waking the second
Mac, and rebooting it so that the agent starts at login. Check that the logs contain no secret, and that a wrong secret
produces the message in `docs/troubleshooting.md`.

**Rationale.** The agent and the fleet client were tested only on loopback. The listener's bind to a Tailscale address and
the reconnection after real network events are the operational requirements, and neither has been seen.

**Dependencies.** Two Macs and a tailnet. The user's approval to install the agent on each one. The installer from the
package.

**Acceptance criteria.**
- The pairing completes with a fingerprint match.
- Each event reconnects within the backoff schedule in `docs/fleet-dashboard.md`.
- The `addresses` output shows the bound address, and the listener refuses connections from outside the allowed networks.
- Every message the app shows matches `docs/troubleshooting.md`.
- The results are recorded in `docs/verification.md`.

**Effort.** 12 hours.

## 8. Launch at login from an installed app

**Scope.** Install the signed app (step 6) or an ad hoc build in `/Applications`, with the user's agreement. Toggle Open at
Login and record each status the system reports: not registered, enabled, requires approval, not found from a build folder,
and unknown. Log out and back in. Check that the app starts once, that quitting and logging in again behaves the same, and
that turning the setting off removes the item. Check that MacFleet appears in System Settings under Login Items.

**Rationale.** The state mapping is tested, but the system's real behaviour and the refusal path are not.

**Dependencies.** Step 6 is preferred. Steps 2 and 5.

**Acceptance criteria.**
- A table of observed transitions covers every status.
- Only one instance runs after login.
- The status text in Settings matches what the system reported.
- `docs/app-settings.md` and `docs/verification.md` are updated.

**Effort.** 6 hours.

## 9. Audit accessibility in the running app

**Scope.** Walk through the popover, Fleet, History, Processes, and Settings with VoiceOver, including the pairing form and
its confirmation. Run the Accessibility Inspector on each window. Test Dynamic Type at the largest size, Increase Contrast,
and Reduce Motion. Operate every control from the keyboard: check the Tab order, focus rings, Space, and Return. Fix each
finding, and add the accessibility identifiers that step 10 needs.

**Rationale.** The accessibility work is verified through presentation tests only. The requirement is about the running UI.

**Dependencies.** Step 2.

**Acceptance criteria.**
- The Accessibility Inspector reports no unlabelled or inaccessible control in the audited windows.
- Every control can be reached and used from the keyboard.
- VoiceOver reads each chart's spoken summary.
- Each finding is fixed, or listed with its reason.

**Effort.** 12 hours.

## 10. Add UI automation tests for settings and navigation

**Scope.** Add an XCUITest target to the Xcode project, not to the Swift package, because XCUITest needs Xcode. Cover these
flows: change a menu bar metric and see the label change; change each refresh rate; open each window from the Navigate
menu and with its shortcut; open Settings on the Notifications pane with ⌘4; check pairing validation for a bad port and an
over-long group name; cancel pairing with Escape. Use the identifiers from step 9, and keep the views free of property
wrappers. The tests must not touch the real keychain or a real remote Mac. Run them on CI.

**Rationale.** The flow tests so far stop at the model. Menu routing, shortcuts, window opening, and the pairing form's
keyboard behaviour are never exercised. The task asked for UI tests where feasible.

**Dependencies.** Step 3 (the project builds), step 9 (identifiers), and a CI runner with a window server.

**Acceptance criteria.**
- At least eight flows pass locally and on CI.
- Twenty consecutive runs pass with no flaky failure.
- The tests leave the keychain and the user's settings unchanged.

**Effort.** 24 hours.

## 11. Measure energy and responsiveness in the running app

**Scope.** Use Instruments and Activity Monitor for 30 minutes in each state: menu bar only, popover open, Processes open,
Fleet with two remote Macs, and History open. Record the idle wakeups per second and CPU. Use Time Profiler during a popover
refresh, and Allocations over two hours. Confirm that the History reload stops when its window closes. Set budgets in
`Config/performance-budgets.env` only where the measurement supports them, and note the reason beside each one.

**Rationale.** The energy policy is checked through constants and tests. No wakeup or main-thread measurement of the running
app exists.

**Dependencies.** Step 2. Instruments from full Xcode.

**Acceptance criteria.**
- A table of 30-minute averages is recorded.
- No state exceeds its wakeup budget, and main-thread work per refresh stays under one frame (16 ms) on this Mac.
- Each finding is fixed or documented.

**Effort.** 12 hours.

## 12. Test the minimum platform and toolchain in CI

**Scope.** Add a macOS 14 job, the deployment target. It runs the tests that can pass there. The identity tests must assert
that a host refuses to load an identity on macOS 14. They must not skip. Add an Xcode 16 job with its Swift 6.1 toolchain.
Fix any API that needs a newer system.

**Rationale.** The project claims macOS 14, but every run so far was on macOS 27 or, in CI, on macOS 15. The claim is
unverified in both directions.

**Dependencies.** CI runners with macOS 14 and Xcode 16. Step 3 for the Xcode build.

**Acceptance criteria.**
- The jobs are green on macOS 14 and macOS 15.
- The identity refusal is asserted on macOS 14.
- The matrix is recorded in `docs/verification.md`.

**Effort.** 8 hours.

## Priority 2: hardening and operations

## 13. Certificate lifecycle and the EC decision

**Scope.** The health report includes the days until the identity expires, with a warning under 30 days. Add
`macfleet-headless identity rotate`, which creates a new identity and keeps the old one until the operator removes it.
Make sure the app's review flow covers a rotation. Decide EC support. Either make EC import work with a documented
PKCS#12 recipe and tests, or record RSA-only as final, with the reason.

**Rationale.** Expiry is currently seen only when a client fails. Rotation is manual, and EC is a known gap.

**Dependencies.** Step 7 for rotation over a real tailnet.

**Acceptance criteria.**
- Tests cover the boundaries at 30 days, 1 day, and expired.
- Rotation keeps the old identity until it is removed.
- The EC decision is recorded, with a test either way.

**Effort.** 10 hours (6 for the lifecycle, 4 for the EC decision).

## 14. Soak test the app and the agent for memory growth

**Scope.** Write a soak script in `scripts/`. It runs the agent in a scratch folder with a simulated client polling every
five seconds, and the app with a remote Mac. Over eight hours it records resident memory and footprint every ten minutes.
At the end it runs `leaks`. Add a one-hour variant that CI can run nightly.

**Rationale.** The budgets cover history growth only. Running process memory has never been measured.

**Dependencies.** Step 2 for the app side. Step 7 for a real remote Mac, though a loopback client is enough for the agent.

**Acceptance criteria.**
- Memory growth after the first hour is below a rate set from the measurement, recorded in the budgets file with its reason.
- `leaks` reports none.
- The script is committed and documented.

**Effort.** 10 hours.

## 15. Bound storage for silent Macs and check the real clock

**Scope.** A Mac that stops reporting keeps its newest open bucket. That is about seven minutes of raw points and up to an
hour of five-minute points. Decide between two options. Either close the bucket after a silence timeout, so every point
rolls up, or keep the trade-off and prove its bound. Add a test over 30 simulated silent days. Then compare the real clock
offset between two Macs over 24 hours, and confirm that the charts stay aligned.

**Rationale.** The trade-off is bounded but untested over long silences. The clock offset is measured but has never been
compared with a second real clock.

**Dependencies.** Step 7 for the real clock check.

**Acceptance criteria.**
- The test shows bounded storage over 30 silent days.
- A 24-hour offset log is recorded.
- The policy is documented in `docs/multi-host-history.md`.

**Effort.** 8 hours.

## 16. Discover the toolchain on Macs with only Xcode

**Scope.** The scripts assume `/Library/Developer/CommandLineTools`. Resolve `DEV` and `SDK` with `xcrun` when that path is
absent. Derive the Swift Testing framework and plugin paths from the toolchain rather than hard-coding them. Apply the same
change to every script that uses the path.

**Rationale.** A Mac with only Xcode cannot run the verified path without setting `DEV` and `SDK` by hand.

**Dependencies.** Command Line Tools and Xcode, both needed to test each path.

**Acceptance criteria.**
- The scripts pass with the Command Line Tools only, with `DEVELOPER_DIR` set to Xcode, and with `DEV` and `SDK` overrides.
- The CI pin in `.github/workflows/ci.yml` is kept or removed on purpose, and the reason is recorded.

**Effort.** 5 hours.

## 17. Write an independent protocol client

**Scope.** Write a small client in a second language, following `docs/remote-protocol.md`. It performs the handshake, checks
the pinned fingerprint, sends the HMAC proof bound to the TLS exporter, and decodes snapshots. Python in `.venv` is the
first choice, as the project rules say. If Python's TLS API cannot read the exporter, use another language, and record why.
Run the client against the headless agent and against the protocol fixtures.

**Rationale.** The protocol has one implementation, so the specification has never been read by anyone else.

**Dependencies.** Step 1 for the limits. The fixtures are already in place.

**Acceptance criteria.**
- The client completes a session with the agent and decodes every fixture.
- Each disagreement found is fixed in the specification or the implementation, with a test.

**Effort.** 8 hours.

## 18. Run the storage gate nightly in CI

**Scope.** Add a scheduled workflow that runs `scripts/swiftc-history-check.sh` and uploads its output. It fails on any
inconsistent trial.

**Rationale.** The storage gate has been run by hand. A regression would not be caught until someone runs it.

**Dependencies.** The CI workflow.

**Acceptance criteria.**
- The nightly run passes on macOS 15.
- A deliberately seeded defect fails the run once, and the defect is then reverted.

**Effort.** 3 hours.

## Priority 3: optional

## 19. Add a support diagnostics bundle

**Scope.** Add `macfleet-headless diagnostics`, and an app menu item that writes a zip. It contains the versions, the
configuration with its secret references, the last 1,000 log lines, the health report, and the OS version. It never
contains the history, identity material, or a client secret.

**Rationale.** Troubleshooting currently asks users to copy logs by hand.

**Dependencies.** None.

**Acceptance criteria.**
- A test seeds known secret strings and key material, and asserts that none appears in the bundle.
- `docs/troubleshooting.md` names the command.

**Effort.** 6 hours.

## Added in the publication pass

Steps 20 and 21 were added after the others. Their numbers follow 19 so that existing references stay valid. Step 21 is
Priority 1, and step 20 is Priority 2.

## 20. Adopt a formatting gate

**Scope.** Choose the house formatting rules: four-space indentation, 120-column lines, and the case-binding style the code
already uses. Apply the formatter to the sources in one mechanical commit, review its diff, and run `swift-format lint
--strict` in `scripts/swiftc-verify.sh`. The Command Line Tools already ship swift-format 6.4.4, so nothing needs installing.
The measured starting point, with a candidate configuration, is 1,424 findings in 132 files: 551 indentation, 298 add-line,
285 line-length, 253 `let` placement in case patterns, 28 trailing commas, 5 import order, 3 extension access levels, and 1
removed line.

**Rationale.** Without a gate, style drifts. The current findings are not bugs, but a gate stops new ones from entering the
code in review.

**Dependencies.** None. The formatter is part of the Command Line Tools.

**Acceptance criteria.**
- The formatting commit changes no behaviour: verify passes with the same test count, and the storage and performance checks
  still pass.
- `swift-format lint --strict` passes in `scripts/swiftc-verify.sh`, and its configuration is committed.
- The README and `docs/verification.md` describe the gate and its result.

**Effort.** 8 hours.

## 21. Restore SwiftPM builds and tests in this sandbox

**Scope.** Find out why the build service's manifest write is refused, the `XCBuildData` write that both build systems hit.
If the sandbox owner can allow that write for the project's own build directory, re-run `swift build` and `swift test` with
`--disable-sandbox`. Do not change the outer sandbox. If the write cannot be allowed, record that `swift test` stays
unavailable here, and keep `swiftc-verify.sh` as the verified path.

**Rationale.** SwiftPM is the normal build path on a Mac with Xcode, and `swift test` has never run here. The `swiftc` path
compiles the same sources and suites, but it is a second build that can drift from the package.

**Dependencies.** The sandbox owner, outside this repository. Step 3 for the Xcode side.

**Acceptance criteria.** `swift build` and `swift test` complete with the same test count as `swiftc-verify.sh`. Otherwise,
the limit is recorded with the exact sandbox denial and the owner's decision.

**Effort.** 4 hours.

## Total estimate and assumptions

**Total: 190 hours** across the 21 steps. By priority: Priority 0 is 44 hours, Priority 1 is 88 hours (steps 6 to 12, and step
21), Priority 2 is 52 hours (steps 13 to 18, and step 20), and Priority 3 is 6 hours. With a 20% contingency, the total is about
228 hours.

**Assumptions.**

- The estimates are for an engineer who knows this repository. They include tests and documentation.
- Full Xcode 16 or later is available for steps 3, 10, 11, and 12. The owner installs it. It cannot be installed from this
  sandbox without writing outside the repository.
- The user supplies an Apple Developer certificate and notarytool profile for step 6. Nothing is committed.
- Two Macs on one tailnet are available for step 7. The user approves installing the agent on each one, and no system
  setting is changed without that approval.
- Physical access to a display session is available for steps 2, 5, 8, and 9.
- Apple's notarization queue time, CI queue time, and the user's own review time are excluded.
- The estimates assume the current architecture. They do not include a new feature beyond what the steps name.
- Screenshots and logs from the user's Mac are kept out of the repository.
- The format estimate in step 20 assumes the house style is fixed in that step, rather than changed later.
