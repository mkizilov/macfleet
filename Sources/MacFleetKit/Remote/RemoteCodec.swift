import Foundation

/// A frame or envelope that a peer sent in a form this build refuses.
public enum RemoteProtocolViolation: Error, Equatable, Sendable {
    case malformed(String)
    case frameTooLarge(Int)
    case emptyFrame
}

/// Encodes and decodes messages as JSON envelopes: `{"version": "1.0", "type": "hello", "body": {...}}`. Dates are
/// numbers of seconds since 1970-01-01 UTC, with fractions kept. Unknown fields are ignored, so a newer peer's extra
/// fields never break decoding.
public enum RemoteCodec {
    public static func encode(_ message: RemoteMessage, version: ProtocolVersion) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        switch message {
        case let .hello(body):
            return try encoder.encode(Wire(version: version, type: "hello", body: body))
        case let .helloAccepted(body):
            return try encoder.encode(Wire(version: version, type: "helloAccepted", body: body))
        case let .authenticate(body):
            return try encoder.encode(Wire(version: version, type: "authenticate", body: body))
        case let .authenticated(body):
            return try encoder.encode(Wire(version: version, type: "authenticated", body: body))
        case let .capabilities(body):
            return try encoder.encode(Wire(version: version, type: "capabilities", body: body))
        case let .subscribe(body):
            return try encoder.encode(Wire(version: version, type: "subscribe", body: body))
        case let .snapshot(body):
            return try encoder.encode(Wire(version: version, type: "snapshot", body: body))
        case let .heartbeat(body):
            return try encoder.encode(Wire(version: version, type: "heartbeat", body: body))
        case let .error(body):
            return try encoder.encode(Wire(version: version, type: "error", body: body))
        case .unknown:
            throw RemoteProtocolViolation.malformed("a message of an unknown type cannot be sent")
        }
    }

    public static func decode(_ data: Data) throws -> RemoteEnvelope {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let header = try decoder.decode(WireHeader.self, from: data)
            let message: RemoteMessage
            switch header.type {
            case "hello":
                message = .hello(try decoder.decode(Wire<ClientHello>.self, from: data).body)
            case "helloAccepted":
                message = .helloAccepted(try decoder.decode(Wire<HostHello>.self, from: data).body)
            case "authenticate":
                message = .authenticate(try decoder.decode(Wire<ClientProof>.self, from: data).body)
            case "authenticated":
                message = .authenticated(try decoder.decode(Wire<HostProof>.self, from: data).body)
            case "capabilities":
                message = .capabilities(try decoder.decode(Wire<CapabilityReport>.self, from: data).body)
            case "subscribe":
                message = .subscribe(try decoder.decode(Wire<SubscribeRequest>.self, from: data).body)
            case "snapshot":
                message = .snapshot(try decoder.decode(Wire<RemoteSnapshot>.self, from: data).body)
            case "heartbeat":
                message = .heartbeat(try decoder.decode(Wire<Heartbeat>.self, from: data).body)
            case "error":
                message = .error(try decoder.decode(Wire<RemoteProtocolError>.self, from: data).body)
            default:
                message = .unknown(type: header.type)
            }
            return RemoteEnvelope(version: header.version, message: message)
        } catch {
            throw RemoteProtocolViolation.malformed(String(describing: error))
        }
    }
}

private struct Wire<Body: Codable>: Codable {
    let version: ProtocolVersion
    let type: String
    let body: Body
}

/// Reads the envelope fields without touching the body, so an unknown type can be recognized.
private struct WireHeader: Decodable {
    let version: ProtocolVersion
    let type: String
}

/// Length-prefixed frames: a 4-byte big-endian length, then the payload. TCP does not keep message boundaries, so the
/// framing is what lets a receiver find one message in the byte stream.
public enum RemoteFrame {
    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw RemoteProtocolViolation.emptyFrame }
        guard payload.count <= RemoteProtocol.maximumFrameBytes else {
            throw RemoteProtocolViolation.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }
}

/// Collects bytes from the stream and returns each complete frame. The length is checked as soon as the header
/// arrives, so an oversized frame is refused without buffering its body.
public struct RemoteFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0 else { throw RemoteProtocolViolation.emptyFrame }
        guard length <= RemoteProtocol.maximumFrameBytes else { throw RemoteProtocolViolation.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(length))
        buffer.removeFirst(4 + length)
        return payload
    }
}
