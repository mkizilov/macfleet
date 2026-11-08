import Foundation
import Testing
@testable import MacFleetKit

/// The repository root, found from this file's location.
let releaseRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

struct ReleaseToolResult {
    let status: Int32
    let output: String
}

/// Runs a system tool and returns its status and combined output. Used only for read-only and scratch-only commands.
func releaseRunTool(_ path: String, _ arguments: [String], in directory: URL? = nil) throws -> ReleaseToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ReleaseToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

private func repositoryText(_ path: String) throws -> String {
    try String(contentsOf: releaseRepositoryRoot.appendingPathComponent(path), encoding: .utf8)
}

/// The value of KEY in an xcconfig file.
private func xcconfigValue(_ key: String, in text: String) -> String? {
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == key {
            return parts[1]
        }
    }
    return nil
}

/// Every value that KEY takes in the Xcode project file, one per build configuration that sets it.
private func projectValues(_ key: String, in project: String) -> [String] {
    project.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key) = "), trimmed.hasSuffix(";") else { return nil }
        return String(trimmed.dropFirst(key.count + 3).dropLast())
    }
}

/// The text of the Release configuration block of the app target, found by its name line.
private func releaseBlock(in project: String) -> String {
    let parts = project.components(separatedBy: "\t\t\tname = Release;")
    guard parts.count > 1 else { return "" }
    return parts[0].components(separatedBy: "\t\t0A").last ?? ""
}

/// Version metadata is written in four places: the version file, the Swift constant, the Xcode project, and the scripts.
/// These checks keep them the same, so a build, its bundle, and its agent always report one version.
@Suite("Release metadata")
struct ReleaseMetadataTests {
    @Test func theSwiftVersionConstantsMatchTheVersionFile() throws {
        let config = try repositoryText("Config/Version.xcconfig")
        #expect(xcconfigValue("MARKETING_VERSION", in: config) == MacFleetVersion.marketing)
        #expect(xcconfigValue("CURRENT_PROJECT_VERSION", in: config) == String(MacFleetVersion.build))
        #expect(xcconfigValue("MACFLEET_BUNDLE_ID", in: config) == MacFleetVersion.bundleIdentifier)
        #expect(xcconfigValue("MACFLEET_MIN_MACOS", in: config) == MacFleetVersion.minimumSystemVersion)
    }

    @Test func theXcodeProjectAgreesWithTheVersionFileInEveryConfiguration() throws {
        let config = try repositoryText("Config/Version.xcconfig")
        let project = try repositoryText("MacFleet.xcodeproj/project.pbxproj")
        let expected = [
            "MARKETING_VERSION": try #require(xcconfigValue("MARKETING_VERSION", in: config)),
            "CURRENT_PROJECT_VERSION": try #require(xcconfigValue("CURRENT_PROJECT_VERSION", in: config)),
            "PRODUCT_BUNDLE_IDENTIFIER": try #require(xcconfigValue("MACFLEET_BUNDLE_ID", in: config)),
        ]
        for (key, value) in expected {
            let values = projectValues(key, in: project)
            #expect(values.count >= 2, "\(key) is set in both Debug and Release")
            #expect(Set(values) == [value], "\(key) in the project differs from Config/Version.xcconfig")
        }
    }

    @Test func releaseBuildsAreOptimizedWholeModuleWithoutAssertions() throws {
        let release = releaseBlock(in: try repositoryText("MacFleet.xcodeproj/project.pbxproj"))
        #expect(release.contains("SWIFT_OPTIMIZATION_LEVEL = \"-O\";"))
        #expect(release.contains("SWIFT_COMPILATION_MODE = wholemodule;"))
        #expect(release.contains("ENABLE_NS_ASSERTIONS = NO;"))
    }

    @Test func signingDefaultsNeedNoCredentialAndKeepTheHardenedRuntime() throws {
        let signing = try repositoryText("Config/Signing.xcconfig")
        #expect(xcconfigValue("CODE_SIGN_IDENTITY", in: signing) == "-")
        #expect(xcconfigValue("ENABLE_HARDENED_RUNTIME", in: signing) == "YES")
        let project = try repositoryText("MacFleet.xcodeproj/project.pbxproj")
        #expect(projectValues("ENABLE_HARDENED_RUNTIME", in: project).allSatisfy { $0 == "YES" })
        #expect(projectValues("CODE_SIGN_IDENTITY", in: project).allSatisfy { $0 == "\"-\"" })
        #expect(projectValues("DEVELOPMENT_TEAM", in: project).isEmpty, "no team is committed")
    }

    @Test func noSigningIdentityOrNotaryProfileIsCommitted() throws {
        for path in ["Config/Version.xcconfig", "Config/Signing.xcconfig", "scripts/package-app.sh", "scripts/notarize.sh"] {
            let text = try repositoryText(path)
            // A real identity is a name followed by a ten-character team ID. The usage example says TEAMID, which is not one.
            let realIdentity = text.range(of: "Developer ID Application: [^\n]*\\([A-Z0-9]{10}\\)", options: .regularExpression) != nil
            #expect(!realIdentity, "\(path) names a signing identity")
            #expect(!text.contains("BEGIN PRIVATE KEY"), "\(path) contains key material")
        }
    }

    @Test func thePackageTargetsTheSameMinimumSystemAsTheVersionFile() throws {
        let config = try repositoryText("Config/Version.xcconfig")
        #expect(xcconfigValue("MACFLEET_MIN_MACOS", in: config) == "14.0")
        #expect(try repositoryText("Package.swift").contains(".macOS(.v14)"))
    }

    @Test func thePropertyListsLint() throws {
        for path in ["Support/launchd/com.macfleet.headless.plist", "Support/app/Info.plist.template"] {
            let url = releaseRepositoryRoot.appendingPathComponent(path)
            let result = try releaseRunTool("/usr/bin/plutil", ["-lint", url.path])
            #expect(result.status == 0, "\(path): \(result.output)")
        }
    }

    @Test func everyShellScriptParses() throws {
        let scripts = try FileManager.default.contentsOfDirectory(
            at: releaseRepositoryRoot.appendingPathComponent("scripts"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "sh" }
        #expect(!scripts.isEmpty)
        for script in scripts {
            let result = try releaseRunTool("/bin/sh", ["-n", script.path])
            #expect(result.status == 0, "\(script.lastPathComponent): \(result.output)")
        }
    }

    /// The CI workflow runs on macOS 15, where the identity tests can pass, and pins the toolchain the scripts are verified
    /// against. No step pipes a script into `tee`, because a pipe would report the status of `tee` and hide a failed budget.
    @Test func theCIWorkflowRunsOnMacOS15WithThePinnedToolchainAndKeepsExitStatus() throws {
        let workflow = try repositoryText(".github/workflows/ci.yml")
        #expect(!workflow.contains("macos-14"), "the identity tests need macOS 15")
        #expect(workflow.contains("runs-on: macos-15"))
        #expect(workflow.contains("DEVELOPER_DIR: /Library/Developer/CommandLineTools"))
        #expect(!workflow.contains("| tee"), "a pipe into tee hides the exit status of the script")
    }

    @Test func theVersionDescriptionNamesTheVersion() {
        #expect(MacFleetVersion.description.contains(MacFleetVersion.marketing))
        #expect(MacFleetVersion.description.contains("remote protocol 1.0"))
    }
}
