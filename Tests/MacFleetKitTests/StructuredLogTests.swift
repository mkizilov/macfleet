import Foundation
import Testing
@testable import MacFleetKit

private let stamp = Date(timeIntervalSince1970: 1_700_000_000.5)

@Suite("Structured diagnostic log")
struct StructuredLogTests {
    @Test func eachRecordIsOneJSONLineWithItsFields() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.log").path
        let log = try StructuredLog(path: path)
        log.write(.info, "session.opened", ["session": .text("abc"), "remote": .text("100.64.0.2")], at: stamp)
        log.write(.warning, "auth.failed", ["reason": .text("wrongProof"), "attempts": .number(3), "final": .flag(true)], at: stamp)

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let records = try StructuredLog.read(path: path)
        #expect(records.map(\.event) == ["session.opened", "auth.failed"])
        #expect(records[0].level == .info)
        #expect(records[0].fields["session"] == .text("abc"))
        #expect(records[1].fields["attempts"] == .number(3))
        #expect(records[1].fields["final"] == .flag(true))
        #expect(records[1].time == stamp)
    }

    @Test func recordsBelowTheMinimumLevelAreNotWritten() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.log").path
        let log = try StructuredLog(path: path, minimumLevel: .info)
        log.write(.debug, "sample.taken")
        log.write(.info, "agent.running")
        #expect(try StructuredLog.read(path: path).map(\.event) == ["agent.running"])
    }

    @Test func theLogIsOwnerOnly() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.log").path
        let log = try StructuredLog(path: path)
        log.write(.info, "agent.starting")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aFullLogMovesAsideAndTheNewFileStartsEmpty() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.log").path
        let log = try StructuredLog(path: path, maximumBytes: 400)
        for index in 0..<20 {
            log.write(.info, "sample.taken", ["index": .number(Double(index))], at: stamp)
        }
        let backup = try StructuredLog.read(path: path + ".1")
        let current = try StructuredLog.read(path: path)
        #expect(!backup.isEmpty)
        #expect(!current.isEmpty)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        #expect(size <= 400)
        // The two files hold the most recent records, contiguous and in order.
        let indices = (backup + current).compactMap { record -> Double? in
            if case let .number(value)? = record.fields["index"] { return value }
            return nil
        }
        #expect(indices.last == 19)
        #expect(indices == (0..<20).map(Double.init).suffix(indices.count))
    }

    @Test func aLogReopenedAppendsRatherThanOverwrites() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.log").path
        try StructuredLog(path: path).write(.info, "first")
        try StructuredLog(path: path).write(.info, "second")
        #expect(try StructuredLog.read(path: path).map(\.event) == ["first", "second"])
    }
}
