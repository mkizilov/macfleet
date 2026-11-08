import Foundation

/// The version of this build. `Config/Version.xcconfig` is the source for the app bundle and the release scripts, and a
/// test keeps these constants equal to it, so the build, the bundle, and the agent always report the same version.
public enum MacFleetVersion {
    public static let marketing = "0.1.0"
    public static let build = 1
    public static let bundleIdentifier = "dev.macfleet.MacFleet"
    public static let minimumSystemVersion = "14.0"

    /// What `macfleet-headless version` prints.
    public static var description: String {
        "MacFleet \(marketing) (build \(build)), remote protocol \(RemoteProtocol.current)"
    }
}
