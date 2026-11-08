import Foundation
@testable import MacFleetKit

/// Scratch directories for the headless agent tests. They live under the repository's `.agent-local` directory and
/// are removed when the test that made them ends.
enum HeadlessScratch {
    static func make() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent-local/headless-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
