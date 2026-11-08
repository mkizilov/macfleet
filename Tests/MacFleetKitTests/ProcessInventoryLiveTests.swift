import Foundation
import Testing
@testable import MacFleetKit

/// This process's counters from the live listing, or nil if macOS did not let this process read its own details.
private func ownCounters() throws -> ProcessCounters? {
    let listings = try DarwinProcessInventory().listing()
    let own = try #require(listings.first(where: { $0.pid == getpid() }))
    guard case let .readable(counters) = own.outcome else { return nil }
    return counters
}

@Suite("Live process listing on this Mac")
struct ProcessInventoryLiveTests {
    @Test func theSystemListingIncludesLaunchd() throws {
        let listings = try DarwinProcessInventory().listing()
        #expect(listings.count > 10)
        #expect(listings.contains(where: { $0.pid == 1 }))
    }

    @Test func thisProcessIsListedWithItsNameStartTimeAndFootprint() throws {
        let listings = try DarwinProcessInventory().listing()
        let own = try #require(listings.first(where: { $0.pid == getpid() }))
        #expect(own.name?.isEmpty == false)

        guard case let .readable(counters) = own.outcome else {
            Issue.record("this process should be readable by its own user, got \(own.outcome)")
            return
        }
        let start = try #require(counters.startMicroseconds)
        let nowMicroseconds = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(start > 0 && start <= nowMicroseconds)
        #expect(counters.footprintBytes > 0)
    }

    /// Checks the timebase conversion against wall time. Without it, Apple silicon reads about 42 times too high or
    /// too low. The bounds are wide because other tests in this process may add CPU time while the loop runs.
    @Test func busyLoopCPUTimeMatchesWallTime() throws {
        let before = try #require(try ownCounters()).cpuNanoseconds
        let started = MonotonicTime.awakeSeconds()
        var sink: UInt64 = 0
        while MonotonicTime.awakeSeconds() - started < 0.3 {
            sink &+= 1
        }
        let wall = MonotonicTime.awakeSeconds() - started
        let after = try #require(try ownCounters()).cpuNanoseconds

        #expect(sink > 0)
        let ratio = Double(after - before) / (wall * 1_000_000_000)
        #expect((0.5...8).contains(ratio))
    }
}
