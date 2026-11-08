import Darwin
import Foundation
import os

public enum HeadlessAgentError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyStarted
    case listenerUnavailable(reason: String)
    case identityUnavailable(reason: String)
    case credentialMissing(clientID: String)
    case credentialInvalid(clientID: String)
    case noSampleYet

    public var description: String {
        switch self {
        case .alreadyStarted: "the agent has already been started"
        case let .listenerUnavailable(reason): "the listener cannot start: \(reason)"
        case let .identityUnavailable(reason): "the identity cannot be loaded: \(reason)"
        case let .credentialMissing(clientID): "no secret is stored for client \"\(clientID)\""
        case let .credentialInvalid(clientID): "the stored secret for client \"\(clientID)\" is not valid"
        case .noSampleYet: "no sample has been taken yet"
        }
    }
}

/// Serves the most recent sample to every session. Sessions never trigger a collection of their own, so the number of
/// clients does not change how often the machine is sampled.
actor LatestSnapshotProvider: SystemMetricsProviding {
    private var latest: SystemSnapshot?

    func store(_ snapshot: SystemSnapshot) {
        latest = snapshot
    }

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        guard let latest else { throw HeadlessAgentError.noSampleYet }
        return latest
    }
}

/// Records host events as they happen. Logging is synchronous, so the log's order matches the order of events, and the
/// session count is kept under a lock so it is correct the moment a session opens.
final class HeadlessEventRecorder: Sendable {
    private let log: StructuredLog
    private let sessionsOpened: OSAllocatedUnfairLock<Int>

    init(log: StructuredLog) {
        self.log = log
        sessionsOpened = OSAllocatedUnfairLock(initialState: 0)
    }

    var totalSessions: Int {
        sessionsOpened.withLock { $0 }
    }

    func record(_ event: RemoteHostEvent) {
        switch event {
        case let .listening(port):
            log.write(.info, "listener.listening", ["port": .number(Double(port))])
        case let .connectionRejected(reason, remote):
            log.write(.warning, "connection.rejected", [
                "reason": .text(reason.rawValue),
                "remote": .text(remote ?? "unknown"),
            ])
        case let .sessionOpened(session, remote):
            sessionsOpened.withLock { $0 += 1 }
            log.write(.info, "session.opened", ["session": .text(session.uuidString), "remote": .text(remote ?? "unknown")])
        case let .authenticated(session, clientID):
            log.write(.info, "session.authenticated", ["session": .text(session.uuidString), "client": .text(clientID)])
        case let .authenticationFailed(session, clientID, reason):
            log.write(.warning, "auth.failed", [
                "session": .text(session.uuidString),
                "client": .text(clientID ?? "unknown"),
                "reason": .text(reason.rawValue),
            ])
        case let .sessionClosed(session, reason):
            log.write(.info, "session.closed", ["session": .text(session.uuidString), "reason": .text(Self.describe(reason))])
        case let .snapshotFailed(session, message):
            log.write(.warning, "snapshot.failed", ["session": .text(session.uuidString), "message": .text(message)])
        }
    }

    private static func describe(_ end: SessionEnd) -> String {
        switch end {
        case .clientClosed: "client_closed"
        case .timedOut: "timed_out"
        case let .refused(code): "refused:\(code.rawValue)"
        case let .transportFailed(description): "transport_failed:\(description)"
        case .stopped: "stopped"
        }
    }
}

/// The headless agent: it samples the machine at the configured interval, serves the latest sample to authenticated
/// clients on its configured address, writes its health and a structured log, and shuts down cleanly on request.
///
/// It listens nowhere unless a listen address is configured. A configured listener that cannot start is a failure, so
/// the process exits and a supervisor can restart it.
public actor HeadlessAgent {
    public static let version = "1.0.0"

    private let configuration: HeadlessConfiguration
    private let secrets: any AgentSecretStore
    private let log: StructuredLog
    private let statusPath: String
    private let latest = LatestSnapshotProvider()
    private let engine: SamplingEngine
    private let recorder: HeadlessEventRecorder
    private var health: HeadlessHealth
    private var host: RemoteMetricsHost?
    private var subscriptionID: UUID?
    private var samplingTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    public init(
        configuration: HeadlessConfiguration,
        secrets: any AgentSecretStore,
        log: StructuredLog,
        samplingProvider: any SystemMetricsProviding,
        statusPath: String
    ) {
        self.configuration = configuration
        self.secrets = secrets
        self.log = log
        self.statusPath = statusPath
        recorder = HeadlessEventRecorder(log: log)
        engine = SamplingEngine(provider: samplingProvider, store: InMemorySnapshotStore())
        let now = Date()
        health = HeadlessHealth(
            state: .starting,
            listener: .disabled(reason: "not started"),
            samplingIntervalSeconds: configuration.samplingIntervalSeconds,
            startedAt: now,
            updatedAt: now,
            processID: getpid(),
            version: Self.version
        )
    }

    /// Runs until `requestShutdown` is called or startup fails. Startup failure throws after the failure is recorded.
    public func run() async throws {
        guard health.state == .starting else { throw HeadlessAgentError.alreadyStarted }
        log.write(.info, "agent.starting", [
            "version": .text(Self.version),
            "pid": .number(Double(getpid())),
            "samplingIntervalSeconds": .number(configuration.samplingIntervalSeconds),
            "listenerConfigured": .flag(configuration.listenAddress != nil),
        ])
        do {
            await startSampling()
            try await startListener()
        } catch {
            await fail(error)
            throw error
        }
        await changeHealth { $0.state = .running }
        log.write(.info, "agent.running")

        await waitForShutdown()
        await shutDown()
    }

    /// Asks the agent to stop. Clients are told first, then sessions close, then sampling stops. Safe to call before
    /// `run` reaches its wait.
    public func requestShutdown() {
        shutdownRequested = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    /// The current health, with the session count read from the listener at this moment.
    public func currentHealth() async -> HeadlessHealth {
        var snapshot = health
        snapshot.activeSessions = await host?.activeSessionCount ?? 0
        snapshot.totalSessions = recorder.totalSessions
        return snapshot
    }

    private func startSampling() async {
        await apply(await engine.collectNow())
        let subscription = await engine.subscribe(interval: SamplingInterval(seconds: configuration.samplingIntervalSeconds))
        subscriptionID = subscription.id
        let updates = subscription.updates
        samplingTask = Task { [weak self] in
            for await update in updates {
                await self?.apply(update)
            }
        }
    }

    private func apply(_ update: SamplingUpdate) async {
        switch update {
        case let .sample(_, snapshot):
            await latest.store(snapshot)
            log.write(.debug, "sample.taken")
            // The agent's own clock, not the provider's, decides whether sampling is alive.
            let received = Date()
            await changeHealth {
                $0.lastSampleAt = received
                $0.sampleCount += 1
            }
        case let .failed(_, message):
            log.write(.warning, "sample.failed", ["message": .text(message)])
            await changeHealth {
                $0.sampleFailures += 1
                $0.lastFailure = message
            }
        }
    }

    private func startListener() async throws {
        guard let address = configuration.listenAddress else {
            await changeHealth { $0.listener = .disabled(reason: "No listenAddress is configured, so no connection is accepted.") }
            log.write(.info, "listener.disabled")
            return
        }
        guard LocalAddresses.isAssigned(address) else {
            throw HeadlessAgentError.listenerUnavailable(
                reason: "\(address) is not assigned to any interface on this Mac. Check that Tailscale is connected, or correct listenAddress."
            )
        }
        guard let identityPath = configuration.identityPath else {
            throw HeadlessAgentError.identityUnavailable(reason: "identityPath is not set")
        }
        let host = try makeHost(address: address, identityPath: identityPath)
        do {
            try await host.start()
        } catch {
            throw HeadlessAgentError.listenerUnavailable(reason: String(describing: error))
        }
        self.host = host
        await changeHealth { $0.listener = .listening(address: address, port: self.configuration.port) }
    }

    private func makeHost(address: String, identityPath: String) throws -> RemoteMetricsHost {
        let identity: Data
        do {
            identity = try ProtectedFile.read(identityPath)
        } catch {
            throw HeadlessAgentError.identityUnavailable(reason: String(describing: error))
        }
        let passphrase: Data
        do {
            guard let stored = try secrets.secret(for: AgentSecretAccount.identityPassphrase) else {
                throw HeadlessAgentError.identityUnavailable(reason: "no passphrase is stored for the identity")
            }
            passphrase = stored
        } catch let error as HeadlessAgentError {
            throw error
        } catch {
            throw HeadlessAgentError.identityUnavailable(reason: String(describing: error))
        }

        var credentials: [RemoteCredential] = []
        for clientID in configuration.clientIDs {
            let secret: Data
            do {
                guard let stored = try secrets.secret(for: AgentSecretAccount.client(clientID)) else {
                    throw HeadlessAgentError.credentialMissing(clientID: clientID)
                }
                secret = stored
            } catch let error as HeadlessAgentError {
                throw error
            } catch {
                throw HeadlessAgentError.credentialMissing(clientID: clientID)
            }
            do {
                credentials.append(try RemoteCredential(clientID: clientID, secret: secret))
            } catch {
                throw HeadlessAgentError.credentialInvalid(clientID: clientID)
            }
        }

        let hostConfiguration = RemoteHostConfiguration(
            displayName: configuration.displayName,
            port: configuration.port,
            listenAddress: address,
            credentials: credentials,
            networkPolicy: (try? configuration.resolvedNetworkPolicy()) ?? .privateNetworks,
            events: { [recorder, weak self] event in
                recorder.record(event)
                Task { await self?.refreshHealth() }
            }
        )
        do {
            return try RemoteMetricsHost(
                configuration: hostConfiguration,
                pkcs12: identity,
                passphrase: String(decoding: passphrase, as: UTF8.self),
                provider: latest
            )
        } catch {
            throw HeadlessAgentError.identityUnavailable(reason: String(describing: error))
        }
    }

    /// Records a change to the health report and writes the report to the status file.
    private func changeHealth(_ change: (inout HeadlessHealth) -> Void) async {
        change(&health)
        health.updatedAt = Date()
        health.activeSessions = await host?.activeSessionCount ?? 0
        health.totalSessions = recorder.totalSessions
        do {
            try HeadlessStatusFile.write(health, to: statusPath)
        } catch {
            log.write(.error, "status.write_failed", ["message": .text(String(describing: error))])
        }
    }

    /// Writes the health report with the current session count, for changes that touch no other field.
    private func refreshHealth() async {
        await changeHealth { _ in }
    }

    private func fail(_ error: Error) async {
        let description = String(describing: error)
        log.write(.error, "agent.failed", ["reason": .text(description)])
        let listenerConfigured = configuration.listenAddress != nil
        await changeHealth { health in
            health.state = .failed
            if listenerConfigured {
                health.listener = .failed(reason: description)
            }
        }
        await host?.stop()
        host = nil
        await stopSampling()
    }

    private func shutDown() async {
        await changeHealth { $0.state = .stopping }
        log.write(.info, "agent.stopping")
        await host?.stop()
        host = nil
        await stopSampling()
        await changeHealth {
            $0.state = .stopped
            $0.activeSessions = 0
        }
        log.write(.info, "agent.stopped")
    }

    private func stopSampling() async {
        if let subscriptionID {
            await engine.unsubscribe(subscriptionID)
        }
        subscriptionID = nil
        let task = samplingTask
        samplingTask = nil
        task?.cancel()
        await task?.value
        await engine.shutdown()
    }

    private func waitForShutdown() async {
        guard !shutdownRequested else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            shutdownContinuation = continuation
        }
    }
}
