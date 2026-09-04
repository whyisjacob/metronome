import Foundation

/// A whole piece laid out as an ordered tempo-map: a name plus a sequence of `SongSection`s whose
/// tempo, meter, subdivision and accents may each differ. Playing the song walks the sections in
/// order, auto-advancing bar-by-bar and section-by-section (see `SongPlan` / `MetronomeEngine`).
///
/// Pure value type — `Codable`/`Equatable` — so a library of songs persists as plain JSON and a
/// future Watch app can reuse it verbatim.
struct Song: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var sections: [SongSection]

    init(id: UUID = UUID(), name: String = "Untitled Song", sections: [SongSection] = []) {
        self.id = id
        self.name = name
        self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case id, name, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Song"
        self.sections = try c.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
    }

    /// Total bars across every section (each section's bars × repeats).
    var totalBars: Int { sections.reduce(0) { $0 + $1.totalBars } }
    var isEmpty: Bool { sections.isEmpty }

    /// Total duration in seconds (sum of section durations; each = totalTicks × secondsPerTick).
    var durationSeconds: Double {
        sections.reduce(0) { $0 + Double($1.totalTicks) * $1.secondsPerTick }
    }
}
