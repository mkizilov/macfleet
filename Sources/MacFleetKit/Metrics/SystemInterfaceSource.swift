import Darwin

/// Lists network interfaces with `getifaddrs` (names, flags, IPv4 addresses) and reads 64-bit byte
/// counters from `sysctl(NET_RT_IFLIST2)`. Neither call needs special permission.
public struct SystemInterfaceSource: InterfaceSource {
    private struct Address {
        var flags: UInt32
        var ipv4: [String]
    }

    public init() {}

    public func interfaces() throws(MetricIssue) -> [RawInterface] {
        let addresses = try addressesByName()
        let totals = try countersByName()
        return Set(addresses.keys).union(totals.keys).sorted().map { name in
            let address = addresses[name]
            let flags = address?.flags ?? 0
            let counters: MetricReading<NetworkTotals> = totals[name].map { .available($0) }
                ?? .unavailable(.notProvided(resource: "interface counters"))
            return RawInterface(
                name: name,
                isUp: flags & UInt32(IFF_UP) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0,
                ipv4Addresses: address?.ipv4 ?? [],
                totals: counters
            )
        }
    }

    private func addressesByName() throws(MetricIssue) -> [String: Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw .kernelCallFailed(call: "getifaddrs", code: errno)
        }
        defer { freeifaddrs(head) }
        var result: [String: Address] = [:]
        var entry = head
        while let current = entry {
            let name = String(cString: current.pointee.ifa_name)
            var address = result[name] ?? Address(flags: 0, ipv4: [])
            address.flags = current.pointee.ifa_flags
            if let socket = current.pointee.ifa_addr, Int32(socket.pointee.sa_family) == AF_INET {
                address.ipv4.append(Self.ipv4Text(socket))
            }
            result[name] = address
            entry = current.pointee.ifa_next
        }
        return result
    }

    private func countersByName() throws(MetricIssue) -> [String: NetworkTotals] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else {
            throw .kernelCallFailed(call: "sysctl(NET_RT_IFLIST2)", code: errno)
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            throw .kernelCallFailed(call: "sysctl(NET_RT_IFLIST2)", code: errno)
        }
        var result: [String: NetworkTotals] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = Self.interfaceName(index: UInt32(message.ifm_index)) {
                        result[name] = NetworkTotals(
                            bytesReceived: message.ifm_data.ifi_ibytes,
                            bytesSent: message.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += size
            }
        }
        return result
    }

    private static func ipv4Text(_ socket: UnsafeMutablePointer<sockaddr>) -> String {
        var address = UnsafeRawPointer(socket).loadUnaligned(as: sockaddr_in.self).sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN))
        return text.string
    }

    private static func interfaceName(index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &buffer) != nil else { return nil }
        return buffer.string
    }
}

private extension Array where Element == CChar {
    /// Decodes a NUL-terminated C string buffer without the deprecated `String(cString:)` initializer.
    var string: String {
        String(decoding: prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
