import Testing
@testable import MacFleetKit

@Suite("Local addresses")
struct LocalAddressTests {
    @Test func everyMacHasLoopbackAndItIsReportedAsSuch() {
        let loopback = LocalAddresses.current().first { $0.address == "127.0.0.1" }
        #expect(loopback?.kind == .loopback)
        #expect(LocalAddresses.isAssigned("127.0.0.1"))
    }

    @Test func aNonAssignedAddressIsNotReportedAsLocal() {
        #expect(!LocalAddresses.isAssigned("10.254.254.254"))
        #expect(!LocalAddresses.isAssigned("0.0.0.0"))
    }

    @Test func linkLocalAddressesAreLeftOut() {
        let addresses = LocalAddresses.current().map(\.address)
        #expect(!addresses.contains { $0.hasPrefix("169.254.") || $0.hasPrefix("fe80") })
    }

    @Test func addressesAreClassifiedByTheirNetwork() {
        #expect(LocalAddresses.kind(of: "127.0.0.1") == .loopback)
        #expect(LocalAddresses.kind(of: "::1") == .loopback)
        #expect(LocalAddresses.kind(of: "100.100.1.2") == .tailscale)
        #expect(LocalAddresses.kind(of: "fd7a:115c:a1e0::1") == .tailscale)
        #expect(LocalAddresses.kind(of: "192.168.1.5") == .other)
    }
}
