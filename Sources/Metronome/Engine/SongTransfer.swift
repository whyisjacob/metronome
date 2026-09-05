import Foundation

/// A self-describing, versioned wrapper for exporting / sharing a single `Song` as a `.maelzelsong` JSON
/// document — the one feature that serves BOTH backup (save to Files / iCloud) and sharing (AirDrop a song
/// to a student). The `version` field lets future readers stay forward-compatible; because `Song` /
/// `SongSection` decode every field with `decodeIfPresent`, and JSON ignores unknown keys, an older app
/// still imports what it understands from a newer file and a newer app fills missing fields with defaults.
struct SongExport: Codable {
    /// Bump only on an incompatible schema change. Readers decode best-effort regardless of this value.
    static let currentVersion = 1

    var version: Int
    var song: Song

    init(song: Song, version: Int = SongExport.currentVersion) {
        self.version = version
        self.song = song
    }

    enum CodingKeys: String, CodingKey { case version, song }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.song = try c.decode(Song.self, forKey: .song)
    }
}

/// Encode/decode a `Song` to/from a shareable document. Pure and Foundation-only, so it is fully
/// unit-testable; the SwiftUI share/import plumbing lives in the views and calls these.
enum SongTransfer {
    /// The document extension. A custom extension (conforming to `public.json`) lets iOS route an opened /
    /// AirDropped file to this app while the bytes remain plain JSON.
    static let fileExtension = "maelzelsong"

    /// Pretty, stable-key JSON of the versioned wrapper — human-readable and diff-friendly in Files.
    static func encode(_ song: Song) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(SongExport(song: song))
    }

    /// Decodes an exported/shared document into a `Song`, tolerantly and with **fresh identity** so an
    /// import is always a NEW library entry (it can never silently overwrite an existing song sharing the
    /// same `id`). Prefers the versioned wrapper; falls back to a bare `Song` JSON.
    static func decode(_ data: Data) throws -> Song {
        let dec = JSONDecoder()
        if let export = try? dec.decode(SongExport.self, from: data) {
            return export.song.reidentified()
        }
        return try dec.decode(Song.self, from: data).reidentified()
    }

    /// A filesystem-safe file name (without extension) derived from the song's name.
    static func fileNameStem(for song: Song) -> String {
        let trimmed = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Song" : trimmed
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return String(base.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) })
    }

    /// A suggested full file name, e.g. `Blues in A.maelzelsong`.
    static func suggestedFileName(for song: Song) -> String {
        "\(fileNameStem(for: song)).\(fileExtension)"
    }
}
