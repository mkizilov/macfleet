# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. It shows placeholder system information in a popover. A separate command-line agent prints the same kind of snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`), for building and running the app bundle

## Layout

| Path | Purpose |
| --- | --- |
| `Package.swift` | Shared Swift package: `MacFleetKit`, `MacFleetState`, `MacFleetUI`, `macfleet-agent`, and tests |
| `Sources/MacFleetKit` | Models, metric providers (system and mock), snapshot storage, wire format |
| `Sources/MacFleetState` | Application state (`FleetStatusModel`) |
| `Sources/MacFleetUI` | SwiftUI popover view |
| `Sources/MacFleetAgent` | Command-line agent target |
| `App/MacFleetApp.swift` | Menu bar app entry point (`MenuBarExtra`) |
| `MacFleet.xcodeproj` | Xcode application project with Debug and Release configurations |
| `Tests/` | Swift Testing suites for the kit and the state layer |
| `scripts/swiftc-verify.sh` | Verified build, test, and agent-run pipeline using `swiftc` only |
| `scripts/swiftc-test-runner/main.swift` | Entry point that runs the Swift Testing suites from the script |

## Verified commands

Run from the repository root.

```sh
scripts/swiftc-verify.sh
```

This script typechecks the manifest, builds `MacFleetKit` and `MacFleetState` as dylibs, typechecks `MacFleetUI`, builds and runs `macfleet-agent`, then compiles and runs the Swift Testing suites. It exits non-zero on the first failure. Outputs go to `.agent-local/swiftc-build/`, which is git-ignored. Remove it with `rm -rf .agent-local/swiftc-build`.

The script uses the Command Line Tools SDK by default. Override with `DEV=/path/to/Developer` or `SDK=/path/to/MacOSX.sdk`.

Last run result: manifest, all modules, and the agent passed. All 8 Swift Testing tests in 4 suites passed.

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

Not verified in this environment: the Xcode build, the app launch, and the popover display. Only a copy of `App/MacFleetApp.swift` with `@State` replaced by `let` typechecked here.

## Run the agent

With full Xcode:

```sh
swift run macfleet-agent
```

Without SwiftPM, the verified script builds the agent at `.agent-local/swiftc-build/macfleet-agent`. The agent prints one JSON snapshot to standard output and exits. Exit status is 1 with a message on standard error if metrics cannot be read.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` before signing for distribution.
- The app is ad-hoc signed for local runs (`CODE_SIGN_IDENTITY = "-"`). No team is configured.
- The menu bar icon uses an SF Symbol rather than a custom asset.
- Placeholder data comes from `ProcessInfo`, `getloadavg`, and the mock provider. The popover shows real host values, not fleet data. Networking transport is not implemented; `FleetWireFormat` only defines the payload.
- The Xcode project has no test targets. Tests run through `scripts/swiftc-verify.sh` or `swift test`.
- The Xcode project file is hand-written. It passes `plutil -lint`, but Xcode has not opened it here.
