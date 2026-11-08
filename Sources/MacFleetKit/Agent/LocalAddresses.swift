import Darwin
import Foundation

/// An address assigned to one of this Mac's interfaces.
public struct LocalAddress: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case loopback
        case tailscale
        case other
    }

    public let interface: String
    public let address: String
    public let kind: Kind
}

/// The addresses this Mac has, so an operator can pick the Tailscale address for the listener. Link-local and
/// scoped addresses are left out, because they cannot be used as a stable listen address.
public enum LocalAddresses {
    public static func current() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [LocalAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, let text = numericText(address) else { continue }
            guard !isLinkLocal(text) else { continue }
            found.append(LocalAddress(
                interface: String(cString: entry.pointee.ifa_name),
                address: text,
                kind: kind(of: text)
            ))
        }
        return found
    }

    /// Whether the address is assigned to this Mac right now.
    public static func isAssigned(_ address: String) -> Bool {
        current().contains { RemoteNetworkPolicy.sameAddress($0.address, address) }
    }

    /// Loopback, the Tailscale ranges, or anything else. The classification is by address, not by interface name.
    public static func kind(of address: String) -> LocalAddress.Kind {
        if contains(address, in: ["127.0.0.0/8", "::1/128"]) {
            return .loopback
        }
        if RemoteNetworkPolicy.privateNetworks.allows(address: address) {
            return .tailscale
        }
        return .other
    }

    /// Whether the address lies in any of the given networks. A list that does not parse matches nothing.
    static func contains(_ address: String, in cidrs: [String]) -> Bool {
        guard let policy = try? RemoteNetworkPolicy(cidrs: cidrs) else { return false }
        return policy.allows(address: address)
    }

    private static func text(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func numericText(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var storage = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &storage, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return text(from: buffer)
        case AF_INET6:
            var storage = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &storage, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return text(from: buffer)
        default:
            return nil
        }
    }
}

extension LocalAddresses {
    /// IPv4 169.254/16 and IPv6 fe80::/10, which are never a stable listen address.
    static func isLinkLocal(_ address: String) -> Bool {
        contains(address, in: ["169.254.0.0/16", "fe80::/10"])
    }
}
