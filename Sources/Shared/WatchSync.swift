import Foundation

/// Only settings are persisted/transferred in the background. Start/stop require a live handshake.
struct WatchSnapshot: Codable, Equatable {
    var schema = 1
    var revision: Int
    var config: MetronomeConfiguration
    var song: Song?
    var pickupTicks: Int

    var startTitle: String { song == nil ? "Start" : "Start Song" }

    static func decode(_ data: Data) throws -> WatchSnapshot {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schema == 1 else { throw SyncError.incompatible }
        return result
    }

    enum SyncError: Error { case incompatible }
}

enum WatchOutput: String, CaseIterable, Codable {
    case vibration, voice, classic, woodblock, beep, rimshot, cowbell
    var sound: MetronomeSound? {
        self == .vibration ? nil : MetronomeSound(rawValue: rawValue)
    }
    var title: String {
        switch self {
        case .vibration: return "Vibration"
        case .voice: return "Spoken count"
        default: return sound?.displayName ?? "Click"
        }
    }
    var symbol: String { self == .vibration ? "waveform" : "speaker.wave.2.fill" }

    /// The watch output choice applies across the entire song, independently of phone voice overrides.
    func playbackSong(_ source: Song) -> Song {
        var song = source.playbackScaled()
        song.voiceEnabled = self == .voice
        for i in song.sections.indices {
            song.sections[i].voiceEnabled = self == .voice
            song.sections[i].speakSubdivisions = self == .voice
        }
        return song
    }
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
