import Network
import Testing
@testable import MacFleetKit

@Suite("Remote network policy")
struct RemoteNetworkPolicyTests {
    private let policy = RemoteNetworkPolicy.privateNetworks

    @Test func tailscaleIPv4AddressesAreAllowed() {
        #expect(policy.allows(address: "100.64.0.1"))
        #expect(policy.allows(address: "100.100.20.30"))
        #expect(policy.allows(address: "100.127.255.254"))
    }

    @Test func addressesJustOutsideTheTailscaleRangeAreRefused() {
        #expect(!policy.allows(address: "100.63.255.255"))
        #expect(!policy.allows(address: "100.128.0.0"))
    }

    @Test func loopbackIsAllowed() {
        #expect(policy.allows(address: "127.0.0.1"))
        #expect(policy.allows(address: "::1"))
    }

    @Test func tailscaleIPv6AddressesAreAllowed() {
        #expect(policy.allows(address: "fd7a:115c:a1e0::1"))
        #expect(policy.allows(address: "fd7a:115c:a1e0:ab12::4"))
    }

    @Test func otherIPv6AddressesAreRefused() {
        #expect(!policy.allows(address: "2001:db8::1"))
        #expect(!policy.allows(address: "fd7a:115c:a1e1::1"))
    }

    @Test func publicAddressesAreRefused() {
        #expect(!policy.allows(address: "8.8.8.8"))
        #expect(!policy.allows(address: "17.0.0.1"))
    }

    @Test func anIPv4MappedAddressIsJudgedAsItsIPv4Address() {
        #expect(policy.allows(address: "::ffff:100.100.1.2"))
        #expect(!policy.allows(address: "::ffff:8.8.8.8"))
    }

    @Test func scopedAndMalformedAddressesAreRefused() {
        #expect(!policy.allows(address: "fe80::1%en0"))
        #expect(!policy.allows(address: "not-an-address"))
        #expect(!policy.allows(address: ""))
    }

    @Test func customNetworksParseAndInvalidOnesAreRefused() throws {
        let office = try RemoteNetworkPolicy(cidrs: ["10.20.0.0/16"])
        #expect(office.allows(address: "10.20.5.6"))
        #expect(!office.allows(address: "10.21.0.1"))
        #expect(!office.allows(address: "100.100.1.2"))

        #expect(throws: RemoteConfigurationError.self) { try RemoteNetworkPolicy(cidrs: ["10.0.0.0/33"]) }
        #expect(throws: RemoteConfigurationError.self) { try RemoteNetworkPolicy(cidrs: ["10.0.0.0"]) }
        #expect(throws: RemoteConfigurationError.self) { try RemoteNetworkPolicy(cidrs: ["nope/8"]) }
    }

    @Test func aConnectionsRemoteAddressIsReadFromItsEndpoint() {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("100.100.1.2"), port: 21440)
        #expect(RemoteNetworkPolicy.address(of: endpoint) == "100.100.1.2")
        #expect(RemoteNetworkPolicy.address(of: .hostPort(host: NWEndpoint.Host("example.com"), port: 21440)) == nil)
    }
}
