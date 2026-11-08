import Foundation
import Testing
@testable import MacFleetKit

/// The fixtures for protocol 1.0, found from this file's location.
private let protocolFixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/protocol-1.0", isDirectory: true)

private func protocolFixture(_ name: String) throws -> Data {
    try Data(contentsOf: protocolFixtureDirectory.appendingPathComponent("\(name).json"))
}

/// Network protocol conformance. The codec and the framing are checked against fixed wire bytes, so a change to the wire
/// format is visible as a changed fixture. Peers built from other versions depend on these bytes staying the same.
@Suite("Protocol 1.0 wire conformance")
struct ProtocolConformanceTests {
    @Test func everyCatalogedMessageEncodesToItsFixtureByteForByte() throws {
        for entry in protocolFixtureCatalog() {
            let encoded = try RemoteCodec.encode(entry.message, version: RemoteProtocol.current)
            let expected = try protocolFixture(entry.name)
            #expect(encoded == expected, "\(entry.name) no longer matches its fixture. A wire change needs scripts/update-protocol-fixtures.sh and a review of the diff.")
        }
    }

    @Test func everyFixtureDecodesBackToTheMessageItWasMadeFrom() throws {
        for entry in protocolFixtureCatalog() {
            let envelope = try RemoteCodec.decode(try protocolFixture(entry.name))
            #expect(envelope.version == RemoteProtocol.current)
            #expect(envelope.message == entry.message, "\(entry.name)")
        }
    }

    @Test func aNewerPeersExtraFieldsDoNotBreakDecoding() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try protocolFixture("subscribe")) as? [String: Any])
        var body = try #require(object["body"] as? [String: Any])
        body["futureFlag"] = true
        object["body"] = body
        object["futureEnvelopeField"] = ["anything": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        let envelope = try RemoteCodec.decode(data)
        #expect(envelope.message == .subscribe(SubscribeRequest(intervalSeconds: 5)))
    }

    @Test func aMessageOfANewerTypeIsKeptAsUnknownAndCannotBeSent() throws {
        let data = Data(#"{"version":"1.0","type":"telemetry","body":{}}"#.utf8)
        let envelope = try RemoteCodec.decode(data)
        #expect(envelope.message == .unknown(type: "telemetry"))
        #expect(throws: RemoteProtocolViolation.self) {
            try RemoteCodec.encode(envelope.message, version: RemoteProtocol.current)
        }
    }

    @Test func aBodyThatDoesNotMatchItsTypeIsMalformed() {
        let data = Data(#"{"version":"1.0","type":"subscribe","body":{"intervalSeconds":"fast"}}"#.utf8)
        #expect(throws: RemoteProtocolViolation.self) {
            try RemoteCodec.decode(data)
        }
    }

    @Test func anErrorCodeFromANewerPeerIsReportedAsUnrecognized() throws {
        let data = Data(#"{"version":"1.0","type":"error","body":{"code":"quotaExceeded","message":"later","retryable":true}}"#.utf8)
        let envelope = try RemoteCodec.decode(data)
        guard case let .error(error) = envelope.message else {
            Issue.record("an error message was expected, got \(envelope.message)")
            return
        }
        #expect(error.code == .unrecognized)
        #expect(error.retryable)
    }

    @Test func aFrameCarriesItsLengthAndReassemblesAcrossChunks() throws {
        let payload = try protocolFixture("heartbeat")
        let frame = try RemoteFrame.encode(payload)
        let declared = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(declared == payload.count)

        var decoder = RemoteFrameDecoder()
        decoder.append(frame.prefix(3))
        #expect(try decoder.nextFrame() == nil, "an incomplete header yields nothing")
        decoder.append(frame.dropFirst(3).prefix(10))
        #expect(try decoder.nextFrame() == nil, "an incomplete body yields nothing")
        decoder.append(frame.dropFirst(13))
        #expect(try decoder.nextFrame() == payload)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test func twoFramesInOneChunkComeOutInOrder() throws {
        let first = try protocolFixture("subscribe")
        let second = try protocolFixture("heartbeat")
        var decoder = RemoteFrameDecoder()
        decoder.append(try RemoteFrame.encode(first) + RemoteFrame.encode(second))
        #expect(try decoder.nextFrame() == first)
        #expect(try decoder.nextFrame() == second)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test func anOversizedFrameIsRefusedBeforeItsBodyArrives() {
        var header = Data()
        withUnsafeBytes(of: UInt32(RemoteProtocol.maximumFrameBytes + 1).bigEndian) { header.append(contentsOf: $0) }
        var decoder = RemoteFrameDecoder()
        decoder.append(header)
        #expect(throws: RemoteProtocolViolation.self) {
            try decoder.nextFrame()
        }
    }

    @Test func aZeroLengthFrameIsRefused() {
        var decoder = RemoteFrameDecoder()
        decoder.append(Data([0, 0, 0, 0]))
        #expect(throws: RemoteProtocolViolation.emptyFrame) {
            try decoder.nextFrame()
        }
    }
}
