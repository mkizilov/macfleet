import Foundation
import Testing
@testable import MacFleetKit

private let current = RemoteProtocol.current
private let host = HostFingerprint(certificateDER: Data("host certificate".utf8))
/// Sub-second precision on purpose: dates must survive the wire exactly.
private let stamp = Date(timeIntervalSince1970: 1_700_000_000.25)

private func sampleMessages() -> [RemoteMessage] {
    [
        .hello(ClientHello(clientID: "laptop-1", supportedVersions: [current], clientNonce: Data(repeating: 1, count: 32))),
        .helloAccepted(HostHello(
            host: HostIdentity(displayName: "studio", fingerprint: host),
            serverNonce: Data(repeating: 2, count: 32)
        )),
        .authenticate(ClientProof(proof: Data(repeating: 3, count: 32))),
        .authenticated(HostProof(proof: Data(repeating: 4, count: 32))),
        .capabilities(CapabilityReport(capabilities: RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot).capabilities)),
        .subscribe(SubscribeRequest(intervalSeconds: 2)),
        .snapshot(RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)),
        .heartbeat(Heartbeat(sequence: 7, sentAt: stamp)),
        .error(RemoteProtocolError(code: .unsupportedVersion, message: "no match", retryable: false, supportedVersions: [current])),
    ]
}

private func json(_ text: String) -> Data {
    Data(text.utf8)
}

@Suite("Remote protocol: encoding")
struct RemoteEncodingTests {
    @Test func everyMessageRoundTripsThroughItsEnvelope() throws {
        for message in sampleMessages() {
            let data = try RemoteCodec.encode(message, version: current)
            #expect(try RemoteCodec.decode(data) == RemoteEnvelope(version: current, message: message))
        }
    }

    @Test func theEnvelopeCarriesTheVersionTypeAndBody() throws {
        let data = try RemoteCodec.encode(.heartbeat(Heartbeat(sequence: 1, sentAt: stamp)), version: current)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? String == "1.0")
        #expect(object["type"] as? String == "heartbeat")
        #expect((object["body"] as? [String: Any])?["sequence"] as? Int == 1)
    }

    @Test func datesAreUnixSecondsOnTheWire() throws {
        let data = try RemoteCodec.encode(.heartbeat(Heartbeat(sequence: 2, sentAt: Date(timeIntervalSince1970: 1_700_000_000.25))), version: current)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["body"] as? [String: Any])?["sentAt"] as? Double == 1_700_000_000.25)
    }

    @Test func datesKeepTheirFullPrecision() throws {
        let heartbeat = Heartbeat(sequence: 9, sentAt: Date(timeIntervalSince1970: 1_700_000_000.125))
        let data = try RemoteCodec.encode(.heartbeat(heartbeat), version: current)
        #expect(try RemoteCodec.decode(data).message == .heartbeat(heartbeat))
    }

    @Test func encodingAMessageOfAnUnknownTypeIsRefused() throws {
        #expect(throws: RemoteProtocolViolation.self) {
            try RemoteCodec.encode(.unknown(type: "future"), version: current)
        }
    }
}

@Suite("Remote protocol: compatibility")
struct RemoteCompatibilityTests {
    @Test func anUnknownMessageTypeDecodesAsUnknownInsteadOfFailing() throws {
        let envelope = try RemoteCodec.decode(json(#"{"version":"1.3","type":"futureThing","body":{"values":[1,2,3]}}"#))
        #expect(envelope == RemoteEnvelope(
            version: ProtocolVersion(major: 1, minor: 3),
            message: .unknown(type: "futureThing")
        ))
    }

    @Test func unknownFieldsAreIgnored() throws {
        let data = json(#"{"version":"1.1","type":"heartbeat","meta":{"trace":"x"},"body":{"sequence":4,"sentAt":1700000000,"extra":true}}"#)
        let envelope = try RemoteCodec.decode(data)
        #expect(envelope.message == .heartbeat(Heartbeat(
            sequence: 4,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )))
        #expect(envelope.version == ProtocolVersion(major: 1, minor: 1))
    }

    @Test func aSnapshotFromANewerHostDecodesWithItsExtraFields() throws {
        let data = try RemoteCodec.encode(.snapshot(RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)), version: current)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(object["body"] as? [String: Any])
        body["gpuTemperature"] = ["unavailable": ["unsupported": ["reason": "not measured"]]]
        object["body"] = body
        let newer = try JSONSerialization.data(withJSONObject: object)
        #expect(try RemoteCodec.decode(newer).message == .snapshot(RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)))
    }

    @Test func aMissingRequiredFieldIsMalformed() {
        #expect(throws: RemoteProtocolViolation.self) {
            try RemoteCodec.decode(json(#"{"version":"1.0","type":"heartbeat","body":{"sequence":1}}"#))
        }
    }

    @Test func anUnparseableVersionIsMalformed() {
        for version in ["1", "1.x", "one.zero", "1.0.1", "", "+1.0", "1.-1"] {
            #expect(throws: RemoteProtocolViolation.self) {
                try RemoteCodec.decode(json(#"{"version":"\#(version)","type":"heartbeat","body":{"sequence":1,"sentAt":0}}"#))
            }
        }
    }

    @Test func aNotJSONFrameIsMalformed() {
        #expect(throws: RemoteProtocolViolation.self) {
            try RemoteCodec.decode(json("not json"))
        }
    }

    @Test func anErrorCodeFromANewerPeerDecodesAsUnrecognized() throws {
        let envelope = try RemoteCodec.decode(json(
            #"{"version":"1.0","type":"error","body":{"code":"quotaExceeded","message":"slow down","retryable":true}}"#
        ))
        guard case let .error(error) = envelope.message else {
            Issue.record("expected an error message")
            return
        }
        #expect(error.code == .unrecognized)
        #expect(error.retryable)
    }

    @Test func aVersionListInAnErrorDecodes() throws {
        let envelope = try RemoteCodec.decode(json(
            #"{"version":"1.0","type":"error","body":{"code":"unsupportedVersion","message":"m","retryable":false,"supportedVersions":["1.0","1.1"]}}"#
        ))
        guard case let .error(error) = envelope.message else {
            Issue.record("expected an error message")
            return
        }
        #expect(error.supportedVersions == [ProtocolVersion(major: 1, minor: 0), ProtocolVersion(major: 1, minor: 1)])
    }
}

@Suite("Remote protocol: framing")
struct RemoteFramingTests {
    @Test func framesArriveIntactWhateverTheChunking() throws {
        let payloads = [Data("one".utf8), Data(repeating: 7, count: 300), Data("three".utf8)]
        var stream = Data()
        for payload in payloads {
            stream.append(try RemoteFrame.encode(payload))
        }
        for chunkSize in 1...9 {
            var decoder = RemoteFrameDecoder()
            var received: [Data] = []
            var offset = stream.startIndex
            while offset < stream.endIndex {
                let end = min(offset + chunkSize, stream.endIndex)
                decoder.append(Data(stream[offset..<end]))
                while let frame = try decoder.nextFrame() {
                    received.append(frame)
                }
                offset = end
            }
            #expect(received == payloads)
        }
    }

    @Test func aZeroLengthFrameIsRejected() {
        var decoder = RemoteFrameDecoder()
        decoder.append(Data([0, 0, 0, 0]))
        #expect(throws: RemoteProtocolViolation.emptyFrame) {
            try decoder.nextFrame()
        }
    }

    @Test func anOversizedFrameIsRefusedFromItsHeaderAlone() {
        var decoder = RemoteFrameDecoder()
        // A header declaring 2 MiB, with no body behind it.
        decoder.append(Data([0x00, 0x20, 0x00, 0x00]))
        #expect(throws: RemoteProtocolViolation.frameTooLarge(2_097_152)) {
            try decoder.nextFrame()
        }
    }

    @Test func anOversizedPayloadIsNotSent() {
        #expect(throws: RemoteProtocolViolation.frameTooLarge(RemoteProtocol.maximumFrameBytes + 1)) {
            try RemoteFrame.encode(Data(count: RemoteProtocol.maximumFrameBytes + 1))
        }
    }
}

@Suite("Remote protocol: negotiation")
struct RemoteNegotiationTests {
    private let v10 = ProtocolVersion(major: 1, minor: 0)
    private let v11 = ProtocolVersion(major: 1, minor: 1)
    private let v20 = ProtocolVersion(major: 2, minor: 0)

    @Test func theHighestCommonVersionIsSelected() {
        #expect(RemoteNegotiation.select(offered: [v10, v11], supported: [v10, v11, v20]) == v11)
    }

    @Test func anOlderHostMeetsANewerClientAtItsOwnVersion() {
        #expect(RemoteNegotiation.select(offered: [v10, v11], supported: [v10]) == v10)
    }

    @Test func noCommonVersionSelectsNothing() {
        #expect(RemoteNegotiation.select(offered: [v20], supported: [v10, v11]) == nil)
    }

    @Test func versionsOrderByMajorThenMinor() {
        #expect(v10 < v11)
        #expect(v11 < v20)
        #expect(!(v20 < v11))
    }

    @Test func aVersionIsWrittenAsItsString() throws {
        let data = try JSONEncoder().encode(v11)
        #expect(String(decoding: data, as: UTF8.self) == "\"1.1\"")
        #expect(try JSONDecoder().decode(ProtocolVersion.self, from: data) == v11)
    }
}

@Suite("Remote snapshots")
struct RemoteSnapshotTests {
    private func system(
        cpu: MetricReading<CPUUtilization> = .unavailable(.notSampled),
        volumes: MetricReading<[VolumeMetrics]> = .unavailable(.notSampled),
        hardware: MetricReading<HardwareSample> = .unavailable(.notSampled)
    ) -> SystemSnapshot {
        SystemSnapshot(
            capturedAt: stamp,
            hostName: "test-mac",
            operatingSystemVersion: "test",
            activeProcessorCount: 8,
            physicalMemoryBytes: 1,
            uptimeSeconds: 1,
            loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0),
            cpu: cpu,
            volumes: volumes,
            hardware: hardware
        )
    }

    @Test func theProjectionKeepsEveryReadingOfTheSample() {
        let sample = MockSystemMetricsProvider.sampleSnapshot
        let snapshot = RemoteSnapshot(system: sample)
        #expect(snapshot.capturedAt == sample.capturedAt)
        #expect(snapshot.cpuTotal == .available(0.25))
        #expect(snapshot.memory == sample.memory)
        #expect(snapshot.storage == sample.volumes)
        #expect(snapshot.network == sample.network)
        #expect(snapshot.thermal == .available(.nominal))
        #expect(snapshot.loadAverage == .available(LoadAverage(oneMinute: 1.5, fiveMinutes: 1.2, fifteenMinutes: 0.9)))
    }

    @Test func anUnavailableSectionKeepsItsReasonAndNeverBecomesZero() {
        let snapshot = RemoteSnapshot(system: system(
            hardware: .unavailable(.unsupported(reason: "No GPU is visible to this process."))
        ))
        #expect(snapshot.cpuTotal == .unavailable(.notSampled))
        #expect(snapshot.thermal == .unavailable(.unsupported(reason: "No GPU is visible to this process.")))
        #expect(snapshot.capabilities.first { $0.metric == .cpu }?.state == .unavailable(reason: "Waiting for a second sample"))
        #expect(snapshot.capabilities.first { $0.metric == .thermal }?.state == .unavailable(
            reason: "No GPU is visible to this process."
        ))
    }

    @Test func aPermissionRestrictionIsReportedAsSuchNotAsUnavailable() {
        let snapshot = RemoteSnapshot(system: system(
            volumes: .unavailable(.permissionRestricted(reason: "Full Disk Access is needed to list volumes."))
        ))
        #expect(snapshot.capabilities.first { $0.metric == .storage }?.state == .permissionRestricted(
            reason: "Full Disk Access is needed to list volumes."
        ))
    }

    @Test func aSampledMeasurementIsSupported() {
        let snapshot = RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)
        #expect(snapshot.capabilities.allSatisfy { $0.state == .supported })
    }

    @Test func capabilitiesListEveryMetricOnceInOrder() {
        let snapshot = RemoteSnapshot(system: system())
        #expect(snapshot.capabilities.map(\.metric) == RemoteMetric.allCases)
    }

    @Test func aSnapshotRoundTripsExactly() throws {
        let snapshot = RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(RemoteSnapshot.self, from: data) == snapshot)
    }
}
