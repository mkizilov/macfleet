import Foundation

// Defines the JSON payload an agent will send to the fleet. No transport exists yet.
public enum FleetWireFormat {
    public static func encode(_ snapshot: SystemSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> SystemSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SystemSnapshot.self, from: data)
    }
}
