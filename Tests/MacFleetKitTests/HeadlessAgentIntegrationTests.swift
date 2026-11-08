import Foundation
import Testing
@testable import MacFleetKit

/// Integration tests: a real headless agent serving real TLS sessions to a real client on loopback. The sampling
/// provider is the mock, so readings are deterministic. Ports come from 21421 to 21439, and the suite runs serially.
@Suite("Headless agent integration", .serialized, .enabled(if: RemoteTestSupport.memoryOnlyImportAvailable))
struct HeadlessAgentIntegrationTests {
    /// A complete agent setup in a scratch directory: an identity, a client secret, a configuration, and the paths the
    /// agent writes to. Everything is removed when the test ends.
    final class Fixture {
        let directory: URL
        let secrets = MemoryAgentSecretStore()
        let identityPath: String
        let statusPath: String
        let logPath: String
        let fingerprint: HostFingerprint
        let credential: RemoteCredential
        let identity: RemoteTestSupport.Identity

        init(clientID: String = "laptop-1") throws {
            directory = try HeadlessScratch.make()
            identity = try RemoteTestSupport.makeIdentity()
            identityPath = directory.appendingPathComponent("identity.p12").path
            statusPath = directory.appendingPathComponent("status.json").path
            logPath = directory.appendingPathComponent("headless.log").path
            try ProtectedFile.write(identity.pkcs12, to: identityPath)
            fingerprint = HostFingerprint(certificateDER: identity.certificateDER)
            credential = try RemoteCredential.generate(clientID: clientID)
            try secrets.setSecret(Data(identity.passphrase.utf8), for: AgentSecretAccount.identityPassphrase)
            try secrets.setSecret(credential.secret, for: AgentSecretAccount.client(clientID))
        }

        func configuration(port: UInt16, listenAddress: String? = "127.0.0.1", interval: Double = 0.5) -> HeadlessConfiguration {
            HeadlessConfiguration(
                displayName: "test-agent",
                listenAddress: listenAddress,
                port: port,
                identityPath: identityPath,
                clientIDs: [credential.clientID],
                secretStore: .keychain,
                samplingIntervalSeconds: interval
            )
        }

        func agent(
            _ configuration: HeadlessConfiguration,
            provider: any SystemMetricsProviding = MockSystemMetricsProvider()
        ) throws -> HeadlessAgent {
            try HeadlessAgent(
                configuration: configuration,
                secrets: secrets,
                log: StructuredLog(path: logPath),
                samplingProvider: provider,
                statusPath: statusPath
            )
        }

        func client(port: UInt16, pin: HostFingerprint? = nil, credential: RemoteCredential? = nil) -> RemoteMetricsClient {
            RemoteMetricsClient(
                endpoint: RemoteEndpoint(host: "127.0.0.1", port: port),
                credential: credential ?? self.credential,
                pinnedHost: pin ?? fingerprint,
                timings: RemoteTimings(heartbeatInterval: 0.5, idleTimeout: 5, handshakeTimeout: 5)
            )
        }

        func records() throws -> [LogRecord] {
            try StructuredLog.read(path: logPath)
        }

        func remove() {
            HeadlessScratch.remove(directory)
        }
    }

    /// Runs the agent in a task, waits for it to report running, runs the body, then asks it to stop and waits for it.
    private func withAgent<T>(
        _ agent: HeadlessAgent,
        _ body: (HeadlessAgent) async throws -> T
    ) async throws -> T {
        let task = Task { try await agent.run() }
        try await waitUntil { await agent.currentHealth().state == .running || task.isCancelled }
        do {
            let result = try await body(agent)
            await agent.requestShutdown()
            try await task.value
            return result
        } catch {
            await agent.requestShutdown()
            _ = try? await task.value
            throw error
        }
    }

    private func waitUntil(timeout: Double = 10, _ condition: () async throws -> Bool) async throws {
        let deadline = MonotonicTime.awakeSeconds() + timeout
        while MonotonicTime.awakeSeconds() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the condition was not met within \(timeout) seconds")
    }

    /// Takes the first `count` snapshots from a client, leaving the stream closes the session.
    private func snapshots(_ count: Int, from client: RemoteMetricsClient) async throws -> [RemoteSnapshot] {
        var received: [RemoteSnapshot] = []
        for try await update in await client.updates(interval: SamplingInterval(seconds: 0.5)) {
            if case let .snapshot(snapshot) = update {
                received.append(snapshot)
                if received.count == count { break }
            }
        }
        return received
    }

    @Test func aClientReadsSnapshotsFromARunningAgentOverTLS() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21421))
        try await withAgent(agent) { _ in
            let received = try await snapshots(2, from: fixture.client(port: 21421))
            #expect(received.count == 2)
            #expect(received.first?.capturedAt == RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot).capturedAt)
            #expect(received.first?.memory == MockSystemMetricsProvider.sampleSnapshot.memory)
        }
        #expect(try fixture.records().contains { $0.event == "session.authenticated" })
    }

    @Test func aStatusReportShowsARunningListenerAndSamples() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21422))
        try await withAgent(agent) { _ in
            try await waitUntil { await agent.currentHealth().sampleCount >= 2 }
            let health = try #require(try HeadlessStatusFile.read(from: fixture.statusPath))
            #expect(health.state == .running)
            #expect(health.listener == .listening(address: "127.0.0.1", port: 21422))
            #expect(health.sampleCount >= 2)
            #expect(health.sampleFailures == 0)
            #expect(HeadlessHealthEvaluation.verdict(health, now: Date()) == .healthy)
        }
    }

    @Test func withNoListenAddressTheAgentSamplesButAcceptsNoConnection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21423, listenAddress: nil))
        try await withAgent(agent) { _ in
            try await waitUntil { await agent.currentHealth().sampleCount >= 1 }
            let health = try #require(try HeadlessStatusFile.read(from: fixture.statusPath))
            guard case .disabled = health.listener else {
                Issue.record("with no address the listener must be disabled, got \(health.listener)")
                return
            }
            #expect(HeadlessHealthEvaluation.verdict(health, now: Date()) == .healthy)

            let client = fixture.client(port: 21423)
            do {
                for try await _ in await client.updates(interval: SamplingInterval(seconds: 0.5)) {
                    Issue.record("a disabled listener must deliver nothing")
                }
            } catch {
                // Refused, as required: nothing listens on the port.
            }
        }
    }

    @Test func aClientWithTheWrongSecretIsRefusedAndTheRefusalIsLogged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21424))
        try await withAgent(agent) { _ in
            let imposter = try RemoteCredential.generate(clientID: "laptop-1")
            do {
                _ = try await snapshots(1, from: fixture.client(port: 21424, credential: imposter))
                Issue.record("a wrong secret must not receive metrics")
            } catch {
                // Expected.
            }
            try await waitUntil { try fixture.records().contains { $0.event == "auth.failed" } }
            let failure = try #require(try fixture.records().first { $0.event == "auth.failed" })
            #expect(failure.fields["reason"] == .text("wrongProof"))
            #expect(failure.fields["client"] == .text("laptop-1"))
            #expect(!(try String(contentsOfFile: fixture.logPath, encoding: .utf8)).contains(imposter.secret.base64EncodedString()))
        }
    }

    @Test func aConnectionToAnotherLocalAddressIsNotServedWhileTheListenerIsLoopbackOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21425))
        try await withAgent(agent) { _ in
            // The listener is bound to 127.0.0.1 only. A connection to another address this Mac has is refused by the
            // system, so the client gets no metrics. The agent's own local-address check is a second guard that the
            // unit tests cover through `LocalAddresses`.
            let other = LocalAddresses.current().first { $0.kind == .tailscale || $0.kind == .other }
            guard let other else { return }
            let client = RemoteMetricsClient(
                endpoint: RemoteEndpoint(host: other.address, port: 21425),
                credential: fixture.credential,
                pinnedHost: fixture.fingerprint,
                timings: RemoteTimings(heartbeatInterval: 0.5, idleTimeout: 5, handshakeTimeout: 2)
            )
            do {
                for try await _ in await client.updates(interval: SamplingInterval(seconds: 0.5)) {
                    Issue.record("a connection to another address must not be served")
                }
            } catch {
                // Refused by the system, as required.
            }
        }
    }

    @Test func aClientThatDisconnectsDoesNotStopTheAgentOrLeakItsSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21426))
        try await withAgent(agent) { _ in
            for _ in 0..<3 {
                _ = try await snapshots(1, from: fixture.client(port: 21426))
            }
            try await waitUntil { await agent.currentHealth().activeSessions == 0 }
            #expect(await agent.currentHealth().activeSessions == 0)
            #expect(await agent.currentHealth().totalSessions == 3)

            // A new client still gets served after the earlier ones left.
            #expect(try await snapshots(1, from: fixture.client(port: 21426)).count == 1)
        }
        let closes = try fixture.records().filter { $0.event == "session.closed" }
        #expect(closes.count >= 3)
    }

    @Test func gracefulShutdownTellsConnectedClientsBeforeClosing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21427))
        let task = Task { try await agent.run() }
        try await waitUntil { await agent.currentHealth().state == .running }

        let client = fixture.client(port: 21427)
        let reader = Task { () -> RemoteProtocolError? in
            do {
                for try await _ in await client.updates(interval: SamplingInterval(seconds: 0.5)) {}
            } catch RemoteClientError.hostRejected(let error) {
                return error
            } catch {
                // The connection closed without a notice.
            }
            return nil
        }
        try await waitUntil { await agent.currentHealth().activeSessions == 1 }

        await agent.requestShutdown()
        try await task.value
        let notice = await reader.value

        #expect(notice?.code == .shuttingDown)
        #expect(notice?.retryable == true)
        let health = try #require(try HeadlessStatusFile.read(from: fixture.statusPath))
        #expect(health.state == .stopped)
        #expect(health.activeSessions == 0)
        let events = try fixture.records().map(\.event)
        #expect(events.contains("agent.stopping"))
        #expect(events.last == "agent.stopped")
    }

    @Test func aFailedSampleIsCountedAndReportedAndSamplingContinues() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = ScriptedProvider(failuresFirst: 2)
        let agent = try fixture.agent(fixture.configuration(port: 21428, listenAddress: nil), provider: provider)
        try await withAgent(agent) { _ in
            try await waitUntil { await agent.currentHealth().sampleCount >= 1 }
            let health = await agent.currentHealth()
            #expect(health.sampleFailures >= 2)
            #expect(health.lastFailure != nil)
            #expect(health.sampleCount >= 1)
            #expect(health.state == .running)
        }
        #expect(try fixture.records().contains { $0.event == "sample.failed" })
    }

    @Test func aListenerThatCannotBindFailsTheAgentAndRecordsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // 10.254.254.254 is not assigned to this Mac, so the listener cannot start.
        let agent = try fixture.agent(fixture.configuration(port: 21429, listenAddress: "10.254.254.254"))
        do {
            try await agent.run()
            Issue.record("an agent with an unusable address must not run")
        } catch let error as HeadlessAgentError {
            #expect(error.description.contains("not assigned"))
        }
        let health = try #require(try HeadlessStatusFile.read(from: fixture.statusPath))
        #expect(health.state == .failed)
        #expect(HeadlessHealthEvaluation.verdict(health, now: Date()) != .healthy)
        #expect(try fixture.records().contains { $0.event == "agent.failed" })
    }

    @Test func aMissingClientSecretStopsTheAgentWithAClearReason() async throws {
        let fixture = try Fixture(clientID: "laptop-1")
        defer { fixture.remove() }
        try fixture.secrets.removeSecret(for: AgentSecretAccount.client("laptop-1"))
        let agent = try fixture.agent(fixture.configuration(port: 21430))
        do {
            try await agent.run()
            Issue.record("an agent without a client secret must not run")
        } catch let error as HeadlessAgentError {
            #expect(error == .credentialMissing(clientID: "laptop-1"))
        }
    }

    @Test func aSecondRunOfTheSameAgentIsRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21431, listenAddress: nil))
        try await withAgent(agent) { _ in }
        do {
            try await agent.run()
            Issue.record("a stopped agent must not run again")
        } catch let error as HeadlessAgentError {
            #expect(error == .alreadyStarted)
        }
    }

    @Test func aClientBoundToThePinnedFingerprintRejectsAnotherHost() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let agent = try fixture.agent(fixture.configuration(port: 21432))
        try await withAgent(agent) { _ in
            let wrong = HostFingerprint(certificateDER: Data("some other host".utf8))
            do {
                _ = try await snapshots(1, from: fixture.client(port: 21432, pin: wrong))
                Issue.record("a client must not trust a host it did not pin")
            } catch {
                // Expected: the TLS verify block refuses the certificate.
            }
        }
    }
}

/// A provider that fails a set number of times before it succeeds. It drives the failure-counting path.
actor ScriptedProvider: SystemMetricsProviding {
    private var remainingFailures: Int

    init(failuresFirst: Int) {
        remainingFailures = failuresFirst
    }

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw MetricIssue.unsupported(reason: "scripted failure")
        }
        return MockSystemMetricsProvider.sampleSnapshot
    }
}
