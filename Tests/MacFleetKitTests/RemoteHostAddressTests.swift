import Testing
@testable import MacFleetKit

@Suite("Remote host addresses")
struct RemoteHostAddressTests {
    @Test func tailscaleAndLocalNamesAreAccepted() throws {
        #expect(try RemoteHostAddress.validate("studio") == "studio")
        #expect(try RemoteHostAddress.validate("studio.tail1234.ts.net") == "studio.tail1234.ts.net")
        #expect(try RemoteHostAddress.validate("  mac-mini.local  ") == "mac-mini.local")
        #expect(try RemoteHostAddress.validate("localhost") == "localhost")
    }

    @Test func privateIPAddressesAreAccepted() throws {
        #expect(try RemoteHostAddress.validate("100.101.102.103") == "100.101.102.103")
        #expect(try RemoteHostAddress.validate("192.168.1.20") == "192.168.1.20")
        #expect(try RemoteHostAddress.validate("10.0.0.5") == "10.0.0.5")
        #expect(try RemoteHostAddress.validate("172.20.1.1") == "172.20.1.1")
        #expect(try RemoteHostAddress.validate("fd7a:115c:a1e0::4") == "fd7a:115c:a1e0::4")
        #expect(try RemoteHostAddress.validate("fd12:3456::1") == "fd12:3456::1")
    }

    @Test func publicAddressesAreRefused() {
        for address in ["8.8.8.8", "172.32.0.1", "2001:db8::1", "::ffff:8.8.8.8", "0.0.0.0", "::"] {
            #expect(throws: RemoteHostAddressError.publicAddress) {
                try RemoteHostAddress.validate(address)
            }
        }
    }

    @Test func malformedNamesAreRefused() {
        #expect(throws: RemoteHostAddressError.empty) { try RemoteHostAddress.validate("   ") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("has space") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("https://studio") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("studio/path") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("-studio") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("studio-") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("a..b") }
        #expect(throws: RemoteHostAddressError.invalidName) { try RemoteHostAddress.validate("naïve.local") }
        #expect(throws: RemoteHostAddressError.tooLong) {
            try RemoteHostAddress.validate(String(repeating: "a", count: 254))
        }
    }

    @Test func portsMustBeNumbersInRange() throws {
        #expect(try RemoteHostAddress.validatePort("21440") == 21440)
        #expect(try RemoteHostAddress.validatePort(" 443 ") == 443)
        #expect(throws: RemoteHostAddressError.invalidPort) { try RemoteHostAddress.validatePort("0") }
        #expect(throws: RemoteHostAddressError.invalidPort) { try RemoteHostAddress.validatePort("65536") }
        #expect(throws: RemoteHostAddressError.invalidPort) { try RemoteHostAddress.validatePort("http") }
        #expect(throws: RemoteHostAddressError.invalidPort) { try RemoteHostAddress.validatePort("") }
    }
}
