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
    ],
    targets: [
        .target(name: "MacFleetKit"),
        .target(name: "MacFleetState", dependencies: ["MacFleetKit"]),
        .target(name: "MacFleetUI", dependencies: ["MacFleetState"]),
        .executableTarget(name: "MacFleetAgent", dependencies: ["MacFleetKit"]),
        .testTarget(name: "MacFleetKitTests", dependencies: ["MacFleetKit"]),
        .testTarget(name: "MacFleetStateTests", dependencies: ["MacFleetState"]),
    ]
)
