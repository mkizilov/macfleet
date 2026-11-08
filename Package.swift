// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacFleet",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacFleetKit", targets: ["MacFleetKit"]),
        .library(name: "MacFleetState", targets: ["MacFleetState"]),
        .library(name: "MacFleetUI", targets: ["MacFleetUI"]),
        .executable(name: "macfleet-agent", targets: ["MacFleetAgent"]),
        .executable(name: "macfleet-headless", targets: ["MacFleetHeadless"]),
    ],
    targets: [
        .target(name: "MacFleetKit", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Metal")]),
        .target(name: "MacFleetState", dependencies: ["MacFleetKit"]),
        .target(name: "MacFleetUI", dependencies: ["MacFleetState"]),
        .executableTarget(name: "MacFleetAgent", dependencies: ["MacFleetKit"]),
        .executableTarget(name: "MacFleetHeadless", dependencies: ["MacFleetKit"]),
        .testTarget(name: "MacFleetKitTests", dependencies: ["MacFleetKit"], exclude: ["Fixtures"]),
        .testTarget(name: "MacFleetStateTests", dependencies: ["MacFleetState"]),
    ]
)
