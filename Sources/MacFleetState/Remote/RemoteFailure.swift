import Foundation
import MacFleetKit

/// Why a Mac is not connected, in terms the app can act on. Transient failures are retried with backoff. Fatal failures
/// stop the retries, because retrying cannot fix them: a wrong secret only adds failed attempts, and a changed
/// certificate needs the user to confirm the new identity first.
public enum RemoteFailure: Equatable, Sendable {
    case unreachable(String)
    case timedOut
    case hostRestarting
    case hostError(String)
    case closed
    case authenticationFailed
    case identityChanged(presented: HostFingerprint?)
    /// The pinned certificate failed its checks, such as its validity dates. Retrying cannot fix it.
    case certificateRejected(reason: String)
    case hostNotProven
    case versionMismatch(supported: [ProtocolVersion])
    case protocolError(String)
    case credentialMissing
    case invalidAddress

    public var isFatal: Bool {
        switch self {
        case .unreachable, .timedOut, .hostRestarting, .hostError, .closed:
            false
        case .authenticationFailed, .identityChanged, .certificateRejected, .hostNotProven, .versionMismatch,
             .protocolError, .credentialMissing, .invalidAddress:
            true
        }
    }

    /// Maps an error from a session onto a failure. Anything the client did not classify is treated as transient.
    public init(_ error: any Error) {
        guard let clientError = error as? RemoteClientError else {
            self = .unreachable(error.localizedDescription)
            return
        }
        switch clientError {
        case let .connectionFailed(detail):
            self = .unreachable(detail)
        case .timedOut:
            self = .timedOut
        case .closed:
            self = .closed
        case let .identityMismatch(presented):
            self = .identityChanged(presented: presented)
        case let .certificateRejected(reason):
            self = .certificateRejected(reason: reason)
        case .hostNotAuthenticated:
            self = .hostNotProven
        case let .protocolViolation(detail):
            self = .protocolError(detail)
        case .invalidEndpoint:
            self = .invalidAddress
        case let .hostRejected(error):
            switch error.code {
            case .authenticationFailed:
                self = .authenticationFailed
            case .unsupportedVersion:
                self = .versionMismatch(supported: error.supportedVersions ?? [])
            case .shuttingDown:
                self = .hostRestarting
            case .timedOut:
                self = .timedOut
            case .malformedMessage, .unexpectedMessage, .frameTooLarge:
                self = .protocolError(error.message)
            case .snapshotUnavailable, .internalError, .unrecognized:
                self = .hostError(error.message)
            }
        }
    }
}

/// The wait after each consecutive failure: the base, doubling each time, never above the cap.
public struct RemoteBackoff: Equatable, Sendable {
    public let baseSeconds: Double
    public let capSeconds: Double

    public static let standard = RemoteBackoff(baseSeconds: 2, capSeconds: 300)

    public init(baseSeconds: Double, capSeconds: Double) {
        self.baseSeconds = baseSeconds
        self.capSeconds = capSeconds
    }

    /// `failures` counts from 1. Zero or a negative count waits the base.
    public func delay(afterFailures failures: Int) -> Duration {
        let exponent = min(max(failures - 1, 0), 30)
        let seconds = min(capSeconds, baseSeconds * pow(2, Double(exponent)))
        return .milliseconds(Int((seconds * 1000).rounded()))
    }
}
