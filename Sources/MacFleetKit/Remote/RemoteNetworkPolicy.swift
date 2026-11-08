import Foundation
import Network

/// One IPv4 or IPv6 network in CIDR form, such as "100.64.0.0/10".
public struct CIDRBlock: Equatable, Sendable {
    private let family: Int32
    private let bytes: [UInt8]
    private let prefixLength: Int

    public init(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0 else {
            throw RemoteConfigurationError.invalidNetworkBlock(text)
        }
        guard let parsed = Self.parse(String(parts[0])), prefix <= parsed.bytes.count * 8 else {
            throw RemoteConfigurationError.invalidNetworkBlock(text)
        }
        family = parsed.family
        bytes = parsed.bytes
        prefixLength = prefix
    }

    func contains(family otherFamily: Int32, bytes address: [UInt8]) -> Bool {
        guard otherFamily == family, address.count == bytes.count else { return false }
        var remaining = prefixLength
        for index in bytes.indices where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(0xFF) << (8 - bits)
            guard bytes[index] & mask == address[index] & mask else { return false }
            remaining -= bits
        }
        return true
    }

    private static func parse(_ text: String) -> (family: Int32, bytes: [UInt8])? {
        for family in [AF_INET, AF_INET6] {
            var buffer = [UInt8](repeating: 0, count: 16)
            if inet_pton(family, text, &buffer) == 1 {
                let count = family == AF_INET ? 4 : 16
                return (family, Array(buffer.prefix(count)))
            }
        }
        return nil
    }
}

/// Decides which peers may connect. The host checks the address of each connection before it reads a byte, so a
/// peer outside these networks never reaches the handshake.
public struct RemoteNetworkPolicy: Equatable, Sendable {
    /// Loopback and the Tailscale ranges: 100.64.0.0/10 for IPv4 and fd7a:115c:a1e0::/48 for IPv6.
    public static let privateNetworks = try! RemoteNetworkPolicy(cidrs: [
        "127.0.0.0/8",
        "::1/128",
        "100.64.0.0/10",
        "fd7a:115c:a1e0::/48",
    ])

    private let blocks: [CIDRBlock]

    public init(cidrs: [String]) throws {
        blocks = try cidrs.map(CIDRBlock.init)
    }

    /// Whether a numeric address is inside an allowed network. A zone suffix such as "%en0" is not allowed: the zone
    /// makes an address local to one interface, and this policy does not accept that.
    public func allows(address: String) -> Bool {
        guard let parsed = Self.parse(address) else { return false }
        return blocks.contains { $0.contains(family: parsed.family, bytes: parsed.bytes) }
    }

    /// Whether the text is one numeric IPv4 or IPv6 address.
    public static func isAddressLiteral(_ text: String) -> Bool {
        parse(text) != nil
    }

    /// Whether the text is the wildcard address, which listens on every interface.
    public static func isUnspecified(_ text: String) -> Bool {
        guard let parsed = parse(text) else { return false }
        return parsed.bytes.allSatisfy { $0 == 0 }
    }

    /// Whether two texts name the same numeric address, so "::1" and "0:0:0:0:0:0:0:1" match.
    public static func sameAddress(_ first: String, _ second: String) -> Bool {
        guard let left = parse(first), let right = parse(second) else { return false }
        return left.family == right.family && left.bytes == right.bytes
    }

    /// The numeric address of a connection's remote end, or nil when it is a name or unknown.
    static func address(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        default: return nil
        }
    }

    private static func parse(_ address: String) -> (family: Int32, bytes: [UInt8])? {
        var buffer = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET6, address, &buffer) == 1 {
            // An IPv4-mapped address (::ffff:a.b.c.d) is the IPv4 address, so the IPv4 networks apply to it.
            let mapped = buffer[0..<10].allSatisfy { $0 == 0 } && buffer[10] == 0xFF && buffer[11] == 0xFF
            return mapped ? (AF_INET, Array(buffer[12..<16])) : (AF_INET6, buffer)
        }
        if inet_pton(AF_INET, address, &buffer) == 1 {
            return (AF_INET, Array(buffer.prefix(4)))
        }
        return nil
    }
}
