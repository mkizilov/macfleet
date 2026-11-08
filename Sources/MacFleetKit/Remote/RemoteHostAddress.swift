import Foundation

public enum RemoteHostAddressError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case invalidName
    /// A public IP address. Pairing reaches only the user's own networks, so the address is refused.
    case publicAddress
    case invalidPort
}

/// Checks the address a user types for a remote Mac. A name, such as a Tailscale MagicDNS name, or a private IP address
/// is accepted. A public IP address is refused, so trust is never offered for a machine outside the user's networks.
public enum RemoteHostAddress {
    static let maximumLength = 253

    private static let privateNetworks = try! RemoteNetworkPolicy(cidrs: [
        "127.0.0.0/8",
        "::1/128",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
        "fc00::/7",
    ])

    /// The trimmed address: a name or a private IP literal.
    public static func validate(_ text: String) throws -> String {
        let address = text.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { throw RemoteHostAddressError.empty }
        guard address.count <= maximumLength else { throw RemoteHostAddressError.tooLong }
        if RemoteNetworkPolicy.isAddressLiteral(address) {
            guard privateNetworks.allows(address: address) else { throw RemoteHostAddressError.publicAddress }
            return address
        }
        guard isName(address) else { throw RemoteHostAddressError.invalidName }
        return address
    }

    public static func validatePort(_ text: String) throws -> UInt16 {
        guard let port = UInt16(text.trimmingCharacters(in: .whitespaces)), port > 0 else {
            throw RemoteHostAddressError.invalidPort
        }
        return port
    }

    /// Dot-separated labels of letters, digits, and hyphens. A label is 1 to 63 characters and does not start or end
    /// with a hyphen.
    private static func isName(_ text: String) -> Bool {
        text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
