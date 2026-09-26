import Foundation

/// Only settings are persisted/transferred in the background. Start/stop require a live handshake.
struct WatchSnapshot: Codable, Equatable {
    var schema = 1
    var revision: Int
    var config: MetronomeConfiguration
    var song: Song?
    var pickupTicks: Int

    static func decode(_ data: Data) throws -> WatchSnapshot {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schema == 1 else { throw SyncError.incompatible }
        return result
    }

    enum SyncError: Error { case incompatible }
}

enum WatchOutput: String, CaseIterable, Codable {
    case vibration, voice
    var title: String { self == .vibration ? "Vibration" : "Spoken count" }
}

/// A claim token makes delayed stop/release messages harmless after a later handoff.
struct WatchOwnership {
    private(set) var token: String?
    mutating func claim() -> String {
        let next = UUID().uuidString
        token = next
        return next
    }
    mutating func release(_ candidate: String) -> Bool {
        guard token == candidate else { return false }
        token = nil
        return true
    }
}
