import Foundation
import Network

/// Carries one accepted `NWConnection` from the listener's callback to the session that owns it. Network framework
/// connections are documented as usable from any thread, and this handle is created once and then used only by the
/// session actor it is handed to. It is the only place a connection crosses an isolation boundary.
struct NetworkConnectionHandle: @unchecked Sendable {
    let connection: NWConnection
    /// The peer's numeric address, when the listener knows it.
    let remoteAddress: String?

    init(connection: NWConnection, remoteAddress: String? = nil) {
        self.connection = connection
        self.remoteAddress = remoteAddress
    }
}

public enum RemoteTransportError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case closed
    case timedOut
}

/// One framed, secured connection. The actor serializes access, and a receive that has a deadline closes the
/// connection when the deadline passes, so a silent peer cannot hold a session open.
actor RemoteConnection {
    private let handle: NetworkConnectionHandle
    private let queue = DispatchQueue(label: "macfleet.remote.connection")
    private var decoder = RemoteFrameDecoder()
    private var deadlineExpired = false

    init(_ handle: NetworkConnectionHandle) {
        self.handle = handle
    }

    /// Waits until TLS has completed. A verification failure surfaces as a failed or waiting connection, and a deadline
    /// closes the connection if neither happens, so a start never waits forever.
    func start(within seconds: Double) async throws {
        deadlineExpired = false
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.expireDeadline()
        }
        defer { timer.cancel() }
        do {
            try await becomeReady()
        } catch {
            if deadlineExpired {
                throw RemoteTransportError.timedOut
            }
            throw error
        }
    }

    private func becomeReady() async throws {
        let connection = handle.connection
        let queue = queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case let .failed(error), let .waiting(error):
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(throwing: RemoteTransportError.connectionFailed("\(error)"))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: RemoteTransportError.closed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            handle.connection.cancel()
        }
    }

    func send(_ message: RemoteMessage, version: ProtocolVersion) async throws {
        let frame = try RemoteFrame.encode(RemoteCodec.encode(message, version: version))
        let connection = handle.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: RemoteTransportError.connectionFailed("\(error)"))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            handle.connection.cancel()
        }
    }

    /// Receives the next message. A nil deadline waits indefinitely. A deadline closes the connection when it passes,
    /// and the receive then fails with `timedOut`.
    func receive(within seconds: Double?) async throws -> RemoteEnvelope {
        deadlineExpired = false
        let timer = seconds.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self.expireDeadline()
            }
        }
        defer { timer?.cancel() }
        do {
            return try RemoteCodec.decode(try await nextFrame())
        } catch {
            if deadlineExpired {
                throw RemoteTransportError.timedOut
            }
            throw error
        }
    }

    /// The TLS exporter for this connection. Nil until TLS has completed.
    func channelBinding() -> Data? {
        RemoteTLS.channelBinding(of: handle.connection)
    }

    /// The numeric address this connection arrived on, which is the host's own address. Nil until the connection is
    /// ready.
    func localAddress() -> String? {
        handle.connection.currentPath?.localEndpoint.flatMap(RemoteNetworkPolicy.address(of:))
    }

    func close() {
        handle.connection.cancel()
    }

    private func expireDeadline() {
        deadlineExpired = true
        handle.connection.cancel()
    }

    private func nextFrame() async throws -> Data {
        while true {
            if let frame = try decoder.nextFrame() {
                return frame
            }
            decoder.append(try await receiveChunk())
        }
    }

    private func receiveChunk() async throws -> Data {
        let connection = handle.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: RemoteTransportError.connectionFailed("\(error)"))
                    } else if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if isComplete {
                        continuation.resume(throwing: RemoteTransportError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            handle.connection.cancel()
        }
    }
}
