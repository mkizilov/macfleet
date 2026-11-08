# MacFleet

MacFleet is a native macOS menu bar application written in Swift 6 and SwiftUI. It shows placeholder system information in a popover. A separate command-line agent prints the same kind of snapshot as JSON.

## Requirements

- macOS 14 or later (deployment target 14.0)
- Full Xcode 16 or later, with its command-line tools selected (`xcode-select`)

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

## Build and test

Run from the repository root.

```sh
swift build                 # debug build of all package targets
swift test                  # runs the Swift Testing suites
swift build -c release      # release build of all package targets
```

## Build and launch the menu bar app

1. Open `MacFleet.xcodeproj` in Xcode.
2. Select the `MacFleet` scheme and the `My Mac` destination.
3. Press Run (⌘R), or build from the command line:

   ```sh
   xcodebuild -project MacFleet.xcodeproj -scheme MacFleet -configuration Debug build
   ```

4. Launch the built `MacFleet.app` from the `DerivedData` products folder shown in the build log. The app has no Dock icon (`LSUIElement`). Its icon, a server-rack SF Symbol, appears in the menu bar. Click it to open the popover, then use Refresh or Quit.

## Run the agent

```sh
swift run macfleet-agent
```

The agent prints one JSON snapshot to standard output and exits. Exit status is 1 with a message on standard error if metrics cannot be read.

## Assumptions

- The bundle identifier `dev.macfleet.MacFleet` is a placeholder. Change `PRODUCT_BUNDLE_IDENTIFIER` before signing for distribution.
- The app is ad-hoc signed for local runs (`CODE_SIGN_IDENTITY = "-"`). No team is configured.
- The menu bar icon uses an SF Symbol rather than a custom asset.
- Placeholder data comes from `ProcessInfo`, `getloadavg`, and the mock provider. The popover shows real host values, not fleet data. Networking transport is not implemented; `FleetWireFormat` only defines the payload.

## Project-local toolchain state

Tool caches and state for this repository stay under `.agent-local/`, which is git-ignored. When SwiftPM cannot write to the default user cache, pass project-local paths:

```sh
swift build \
  --cache-path .agent-local/cache/swiftpm \
  --config-path .agent-local/state/swiftpm-config \
  --security-path .agent-local/state/swiftpm-security \
  --scratch-path .agent-local/build
```
