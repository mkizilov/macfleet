import Foundation
import Testing
@testable import MacFleetKit

/// A stand-in for macfleet-headless that answers the two commands the installer runs. It is a shell script in the test's
/// own scratch directory, so no agent runs and nothing listens on a port.
private func agentStandIn(in directory: URL, validates: Bool = true) throws -> URL {
    let url = directory.appendingPathComponent("macfleet-headless")
    let check = validates ? "echo \"configuration is valid: test\"" : "echo \"port is in use\" >&2; exit 2"
    let script = """
    #!/bin/sh
    case "$1" in
      version) echo "MacFleet 0.1.0 (build 1), remote protocol 1.0" ;;
      check) \(check) ;;
      *) exit 2 ;;
    esac

    """
    try script.write(to: url, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A scratch directory under the repository's .agent-local, removed afterwards. Synchronous, because the scripts run as
/// child processes and the tests wait for them.
private func installScratch<T>(_ body: (URL) throws -> T) throws -> T {
    let root = releaseRepositoryRoot.appendingPathComponent(".agent-local/install-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

private func installerScript(_ name: String) -> String {
    releaseRepositoryRoot.appendingPathComponent("scripts/\(name)").path
}

/// The install and uninstall scripts, run against a scratch prefix. They are run with --prefix, --launch-agents and
/// --log-dir inside the test's directory, so they never touch the real Library folders, and --load is never given.
@Suite("Agent install and uninstall scripts")
struct AgentInstallScriptTests {
    private struct Layout {
        let root: URL
        let prefix: URL
        let agents: URL
        let logs: URL
        let binary: URL
        let config: URL
    }

    private func layout(in root: URL, validates: Bool = true) throws -> Layout {
        let config = root.appendingPathComponent("source-headless.json")
        try "{\"displayName\": \"test\"}".write(to: config, atomically: false, encoding: .utf8)
        return Layout(
            root: root,
            prefix: root.appendingPathComponent("prefix"),
            agents: root.appendingPathComponent("agents"),
            logs: root.appendingPathComponent("Logs/MacFleet", isDirectory: true),
            binary: try agentStandIn(in: root, validates: validates),
            config: config
        )
    }

    private func installArguments(_ layout: Layout, extra: [String] = []) -> [String] {
        [
            installerScript("install-agent.sh"),
            "--binary", layout.binary.path,
            "--config", layout.config.path,
            "--prefix", layout.prefix.path,
            "--launch-agents", layout.agents.path,
            "--log-dir", layout.logs.path,
        ] + extra
    }

    private func uninstallArguments(_ layout: Layout, extra: [String] = []) -> [String] {
        [
            installerScript("uninstall-agent.sh"),
            "--prefix", layout.prefix.path,
            "--launch-agents", layout.agents.path,
        ] + extra
    }

    private func withLayout(_ body: (Layout) throws -> Void) throws {
        try installScratch { root in
            try body(try layout(in: root))
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    /// A package keeps the launchd template in launchd/, and a checkout keeps it in Support/launchd/. The installer must
    /// find it in the package layout too, as a package holds no Support folder.
    @Test func theInstallerFindsItsTemplateInThePackageLayout() throws {
        try withLayout { layout in
            let package = layout.root.appendingPathComponent("package", isDirectory: true)
            let scripts = package.appendingPathComponent("scripts", isDirectory: true)
            let launchd = package.appendingPathComponent("launchd", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: launchd, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: installerScript("install-agent.sh")), to: scripts.appendingPathComponent("install-agent.sh"))
            let template = releaseRepositoryRoot.appendingPathComponent("Support/launchd/com.macfleet.headless.plist")
            try FileManager.default.copyItem(at: template, to: launchd.appendingPathComponent("com.macfleet.headless.plist"))

            let result = try releaseRunTool("/bin/sh", [
                scripts.appendingPathComponent("install-agent.sh").path,
                "--binary", layout.binary.path,
                "--config", layout.config.path,
                "--prefix", layout.prefix.path,
                "--launch-agents", layout.agents.path,
                "--log-dir", layout.logs.path,
                "--apply",
            ])
            #expect(result.status == 0, "\(result.output)")
            #expect(!result.output.contains("template is missing"))
        }
    }

    /// The documented minimal file has only the required fields, and the optional ones take their documented defaults.
    @Test func aConfigurationWithOnlyTheRequiredFieldsLoadsWithTheDocumentedDefaults() throws {
        try installScratch { directory in
            let path = directory.appendingPathComponent("minimal.json")
            try "{\"displayName\": \"studio\", \"secretStore\": {\"kind\": \"keychain\"}}".write(to: path, atomically: false, encoding: .utf8)
            let loaded = try HeadlessConfiguration.load(from: path.path)
            #expect(loaded.port == RemoteProtocol.defaultPort)
            #expect(loaded.clientIDs == [])
            #expect(loaded.samplingIntervalSeconds == 10)
            #expect(loaded.listenAddress == nil)
            #expect(loaded.secretStore == .keychain)
        }
    }

    @Test func aDryRunPlansTheInstallAndWritesNothing() throws {
        try withLayout { layout in
            let result = try releaseRunTool("/bin/sh", installArguments(layout))
            #expect(result.status == 0, "\(result.output)")
            #expect(result.output.contains("dry run: nothing was written"))
            #expect(FileManager.default.fileExists(atPath: layout.prefix.path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.agents.path) == false)
        }
    }

    @Test func applyInstallsTheBinaryAConfigurationAndAnAgentDefinition() throws {
        try withLayout { layout in
            let result = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            #expect(result.status == 0, "\(result.output)")

            let installedBinary = layout.prefix.appendingPathComponent("bin/macfleet-headless")
            #expect(FileManager.default.isExecutableFile(atPath: installedBinary.path))

            let installedConfig = layout.prefix.appendingPathComponent("config/headless.json")
            #expect(try permissions(installedConfig) == 0o600, "the configuration is owner-only")

            let plist = layout.agents.appendingPathComponent("com.macfleet.headless.plist")
            let definition = try String(contentsOf: plist, encoding: .utf8)
            #expect(definition.contains(installedBinary.path))
            #expect(definition.contains(installedConfig.path))
            #expect(definition.contains(layout.logs.path))
            #expect(!definition.contains("__MACFLEET"), "every placeholder is replaced")
            let lint = try releaseRunTool("/usr/bin/plutil", ["-lint", plist.path])
            #expect(lint.status == 0)

            let manifest = try String(contentsOf: layout.prefix.appendingPathComponent("install-manifest.txt"), encoding: .utf8)
            #expect(manifest.contains("config_created_by_install=yes"))
            #expect(manifest.contains("launch_agent=\(plist.path)"))
            #expect(FileManager.default.fileExists(atPath: layout.logs.path))
            #expect(!result.output.contains("loaded com.macfleet.headless"), "nothing is loaded without --load")
        }
    }

    @Test func reinstallingKeepsTheConfigurationAlreadyInPlace() throws {
        try withLayout { layout in
            _ = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            let installedConfig = layout.prefix.appendingPathComponent("config/headless.json")
            try "{\"pinned\": \"kept\"}".write(to: installedConfig, atomically: false, encoding: .utf8)
            try "{\"displayName\": \"replacement\"}".write(to: layout.config, atomically: false, encoding: .utf8)

            let result = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            #expect(result.status == 0, "\(result.output)")
            #expect(try String(contentsOf: installedConfig, encoding: .utf8) == "{\"pinned\": \"kept\"}")
            let manifest = try String(contentsOf: layout.prefix.appendingPathComponent("install-manifest.txt"), encoding: .utf8)
            #expect(manifest.contains("config_created_by_install=yes"), "the first install still owns the configuration")
        }
    }

    @Test func aBinaryThatFailsItsValidationInstallsNothing() throws {
        try installScratch { root in
            let layout = try layout(in: root, validates: false)
            let result = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            #expect(result.status == 2)
            #expect(result.output.contains("does not validate"))
            #expect(FileManager.default.fileExists(atPath: layout.prefix.path) == false)
        }
    }

    @Test func loadingNeedsAnExplicitApply() throws {
        try withLayout { layout in
            let result = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--load"]))
            #expect(result.status == 2)
            #expect(result.output.contains("--load needs --apply"))
            #expect(FileManager.default.fileExists(atPath: layout.prefix.path) == false)
        }
    }

    @Test func pathsThatWouldCorruptTheDefinitionAreRefused() throws {
        try withLayout { layout in
            let risky = layout.root.appendingPathComponent("a|b")
            var arguments = installArguments(layout, extra: ["--apply"])
            if let index = arguments.firstIndex(of: "--prefix") {
                arguments[index + 1] = risky.path
            }
            let result = try releaseRunTool("/bin/sh", arguments)
            #expect(result.status == 2)
            #expect(result.output.contains("may not contain"))
        }
    }

    @Test func uninstallRemovesWhatInstallInstalledAndKeepsTheConfiguration() throws {
        try withLayout { layout in
            _ = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))

            let plan = try releaseRunTool("/bin/sh", uninstallArguments(layout))
            #expect(plan.status == 0)
            #expect(plan.output.contains("dry run: nothing was removed"))
            #expect(plan.output.contains("keep:    "))

            let removal = try releaseRunTool("/bin/sh", uninstallArguments(layout, extra: ["--apply"]))
            #expect(removal.status == 0, "\(removal.output)")
            #expect(FileManager.default.fileExists(atPath: layout.prefix.appendingPathComponent("bin/macfleet-headless").path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.agents.appendingPathComponent("com.macfleet.headless.plist").path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.prefix.appendingPathComponent("install-manifest.txt").path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.prefix.appendingPathComponent("config/headless.json").path), "the configuration is kept")
            #expect(FileManager.default.fileExists(atPath: layout.logs.path), "the logs are kept")
        }
    }

    @Test func purgeRemovesTheConfigurationAndLogsOnlyWhenAsked() throws {
        try withLayout { layout in
            _ = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            let removal = try releaseRunTool("/bin/sh", uninstallArguments(layout, extra: ["--apply", "--purge-config", "--purge-logs"]))
            #expect(removal.status == 0, "\(removal.output)")
            #expect(FileManager.default.fileExists(atPath: layout.prefix.appendingPathComponent("config/headless.json").path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.logs.path) == false)
        }
    }

    /// A configuration that was already in place before install is the operator's. A purge must keep it.
    @Test func aPurgeKeepsAConfigurationTheInstallerDidNotCreate() throws {
        try withLayout { layout in
            let installedConfig = layout.prefix.appendingPathComponent("config/headless.json")
            try FileManager.default.createDirectory(at: installedConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\"pinned\": \"operator\"}".write(to: installedConfig, atomically: false, encoding: .utf8)
            _ = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))

            let removal = try releaseRunTool("/bin/sh", uninstallArguments(layout, extra: ["--apply", "--purge-config"]))
            #expect(removal.status == 0, "\(removal.output)")
            #expect(removal.output.contains("the installer did not create it"))
            #expect(try String(contentsOf: installedConfig, encoding: .utf8) == "{\"pinned\": \"operator\"}")
        }
    }

    /// A damaged manifest that points the log directory somewhere other than a MacFleet folder must not delete it.
    @Test func aPurgeRefusesALogDirectoryThatIsNotAMacFleetFolder() throws {
        try withLayout { layout in
            _ = try releaseRunTool("/bin/sh", installArguments(layout, extra: ["--apply"]))
            let manifest = layout.prefix.appendingPathComponent("install-manifest.txt")
            let damaged = try String(contentsOf: manifest, encoding: .utf8)
                .replacingOccurrences(of: "log_directory=\(layout.logs.path)", with: "log_directory=\(layout.root.path)")
            try damaged.write(to: manifest, atomically: false, encoding: .utf8)

            let removal = try releaseRunTool("/bin/sh", uninstallArguments(layout, extra: ["--apply", "--purge-logs"]))
            #expect(removal.status == 2)
            #expect(removal.output.contains("must be a MacFleet directory"))
            #expect(FileManager.default.fileExists(atPath: layout.root.path), "nothing outside the manifest's log folder is removed")
        }
    }

    @Test func uninstallWithoutAManifestRemovesNothing() throws {
        try withLayout { layout in
            let result = try releaseRunTool("/bin/sh", uninstallArguments(layout, extra: ["--apply"]))
            #expect(result.status == 2)
            #expect(result.output.contains("no install manifest"))
        }
    }
}
