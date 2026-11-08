import Foundation
import Testing
@testable import MacFleetKit

@Suite("Disk capacity calculation")
struct DiskUsageCalculatorTests {
    @Test func utilizationIsUsedShareOfTotal() throws {
        let capacity = try DiskUsageCalculator.capacity(total: 1_000, available: 600)
        #expect(capacity.usedBytes == 400)
        #expect(abs(capacity.utilization - 0.4) < 1e-12)
    }

    @Test func fullVolumeIsOneHundredPercent() throws {
        let capacity = try DiskUsageCalculator.capacity(total: 1_000, available: 0)
        #expect(capacity.utilization == 1)
    }

    @Test func zeroTotalIsInconsistent() {
        #expect(throws: MetricIssue.inconsistentStorageCounters) {
            try DiskUsageCalculator.capacity(total: 0, available: 0)
        }
    }

    @Test func availableAboveTotalIsInconsistent() {
        #expect(throws: MetricIssue.inconsistentStorageCounters) {
            try DiskUsageCalculator.capacity(total: 100, available: 101)
        }
    }

    @Test func missingTotalPropagatesItsIssue() {
        let reading = DiskUsageCalculator.reading(
            total: .unavailable(.notProvided(resource: "total capacity")),
            available: .available(10)
        )
        #expect(reading == .unavailable(.notProvided(resource: "total capacity")))
    }

    @Test func missingAvailablePropagatesItsIssue() {
        let reading = DiskUsageCalculator.reading(
            total: .available(100),
            available: .unavailable(.permissionDenied(resource: "available capacity"))
        )
        #expect(reading == .unavailable(.permissionDenied(resource: "available capacity")))
    }
}

@Suite("Volume resource failures")
struct VolumeFailureMappingTests {
    @Test func permissionErrorsAreReportedAsDenied() {
        let issue = FileManagerVolumeSource.issue(for: CocoaError(.fileReadNoPermission), resource: "capacity")
        #expect(issue == .permissionDenied(resource: "capacity"))
    }

    @Test func missingFilesMeanTheVolumeDisconnected() {
        #expect(FileManagerVolumeSource.issue(for: CocoaError(.fileNoSuchFile), resource: "capacity") == .volumeDisconnected)
        #expect(FileManagerVolumeSource.issue(for: CocoaError(.fileReadNoSuchFile), resource: "capacity") == .volumeDisconnected)
    }

    @Test func otherCocoaErrorsKeepTheirCode() {
        let error = CocoaError(.fileReadUnknown)
        let issue = FileManagerVolumeSource.issue(for: error, resource: "capacity")
        #expect(issue == .readFailed(resource: "capacity", code: (error as NSError).code))
    }
}

@Suite("Live mounted volumes")
struct LiveVolumeTests {
    @Test func rootVolumeReportsCapacity() throws {
        let volumes = try FileManagerVolumeSource().volumes()
        let root = try #require(volumes.first { $0.mountPoint == "/" })
        let total = try #require(root.totalBytes.availableValue)
        let available = try #require(root.availableBytes.availableValue)
        #expect(total > 0)
        #expect(available <= total)
    }
}
