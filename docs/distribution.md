# Release and distribution

This page covers how MacFleet is versioned, built, signed, notarized, and checked. Local development needs none of it:
`scripts/swiftc-verify.sh` builds and tests with no credential.

## Versions

`Config/Version.xcconfig` is the single source of the version:

| Key | Value | Used by |
| --- | --- | --- |
| `MARKETING_VERSION` | `0.1.0` | The app's short version, the package names, and `macfleet-headless version` |
| `CURRENT_PROJECT_VERSION` | `1` | The bundle build number |
| `MACFLEET_BUNDLE_ID` | `dev.macfleet.MacFleet` | The app bundle identifier |
| `MACFLEET_MIN_MACOS` | `14.0` | The deployment target, the Swift target, and `LSMinimumSystemVersion` |

Three other places must agree with it, and tests and `scripts/check-release.sh` fail when they drift:
the Xcode project (both configurations), the Swift constants in `Sources/MacFleetKit/Release/MacFleetVersion.swift`, and
the `Info.plist` template that `package-app.sh` fills in.

The remote protocol has its own version, `1.0`, separate from the app's version. A change to the wire format is a protocol
change and has its own rules in [remote-protocol.md](remote-protocol.md#negotiation-and-compatibility).

To release a new version, change `MARKETING_VERSION` and, for every build, `CURRENT_PROJECT_VERSION`, and then the Swift
constants and the project file to match. Run `scripts/check-release.sh`.

## Build configurations

- **Debug** keeps assertions and debug information. It is the default for `swift build` and the Xcode scheme.
- **Release** compiles with `-O`, whole-module optimization, and no assertions (`ENABLE_NS_ASSERTIONS = NO`). The test
  `releaseBuildsAreOptimizedWholeModuleWithoutAssertions` checks these settings.

`scripts/package-app.sh` builds Release-equivalent code with the same flags, so the packaged app is the optimized build.

## Signing

`Config/Signing.xcconfig` signs ad hoc (`CODE_SIGN_IDENTITY = -`) by default. That needs no credential and runs on the Mac
that built it. The hardened runtime is on for every build, because notarization requires it.

A Developer ID identity is supplied at packaging time, never committed:

1. Set `MACFLEET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"` in the environment, or
2. Put `CODE_SIGN_IDENTITY = Developer ID Application: Name (TEAMID)` in `Config/Signing.local.xcconfig`. This file is
   git-ignored.

The test `noSigningIdentityOrNotaryProfileIsCommitted` fails if a real identity or key material is found in a committed
file.

`scripts/package-app.sh` signs inside out (each library, the executable, the bundle, then the agent), with
`--options runtime`, and verifies the result with `codesign --verify --strict`. A Developer ID build gets a secure
timestamp. An ad hoc build gets none. The app's signing report is written beside the packages.

## Notarization (optional)

Notarization needs an Apple Developer account and a Developer ID. It is never run in CI and never asks for a password.

1. Create a notarytool keychain profile once, on your Mac. Use an app-specific password or an API key, as Apple describes:
   `xcrun notarytool store-credentials macfleet-notary`.
2. Package with a Developer ID:
   `MACFLEET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" sh scripts/package-app.sh`.
3. Notarize and staple:
   `MACFLEET_NOTARY_PROFILE=macfleet-notary sh scripts/notarize.sh`.

`notarize.sh` submits the zip, waits, staples the ticket, validates it, runs `spctl`, and writes
`dist/MacFleet-<version>-notarized.zip` with its checksum. The headless agent is a command-line tool in a tarball and is
not notarized here. Gatekeeper does not check it the way it checks an app.

## Checksums

`dist/SHA256SUMS` lists the SHA-256 of each package. Check them with `shasum -a 256 -c SHA256SUMS`.

## Agent package and its scripts

The headless package contains the binary, its libraries, the launchd template, the install and uninstall scripts, and the
documents. It is installed by `scripts/install-agent.sh` as described in [installation.md](installation.md). Installation
writes nothing unless `--apply` is given, and loads nothing unless `--load` is given too. Removal keeps the configuration
and logs unless asked. Both scripts are covered by `AgentInstallScriptTests`, which run them against a scratch folder.

## Performance and memory budgets

`scripts/performance-check.sh` builds the optimized libraries and the two benchmarks, runs them, and fails when a
measurement exceeds its ceiling in `Config/performance-budgets.env`. The ceilings sit well above the measured numbers, so
only a real regression fails it. A change to a budget belongs in the same commit as the measurement that justifies it.

The check measures dashboard work per sample, history save cost, the week-chart and seven-day summary queries, fleet
ingest cost, memory added by seven days of history, and reopen time.

It does not measure the resident memory of a running app or agent. That needs a running process, and the app is not
launched by any script here. Measure it by hand with Activity Monitor or `footprint <pid>` while the app runs, and record
the number in the release notes.

## Continuous integration

`.github/workflows/ci.yml` runs on a macOS runner on each push and pull request. Its jobs need no secret:

- `static` runs `scripts/check-release.sh`.
- `test` runs `scripts/swiftc-verify.sh`, which builds and tests every module with the headless smoke check.
- `performance` runs `scripts/performance-check.sh` against the budgets, and uploads its log.
- `package` runs `scripts/package-app.sh` with ad hoc signing and uploads the packages.

CI does not notarize, does not sign with a Developer ID, and does not store a credential. A runner's timing is noisier than
a developer Mac's, so a performance failure on CI is a prompt to rerun it locally before changing a budget.

## Platform limits

- Apple silicon only. Packages are `arm64`. The project's Metal-based GPU metrics assume it.
- macOS 14 is the minimum. The history store uses the `kSecImportToMemoryOnly` option only on macOS 15 and later, and on
  macOS 14 the headless agent refuses to load an identity rather than write the keychain.
- The app is not sandboxed, so outgoing connections need no entitlement. If sandboxing is enabled later, add
  `com.apple.security.network.client`.
- Launch at login uses `SMAppService`, which works only from an installed app. From a build folder the setting says so.
