import Foundation

/// A whole piece laid out as an ordered tempo-map: a name plus a sequence of `SongSection`s whose
/// tempo, meter, subdivision and accents may each differ. Playing the song walks the sections in
/// order, auto-advancing bar-by-bar and section-by-section (see `SongPlan` / `MetronomeEngine`).
///
/// Pure value type — `Codable`/`Equatable` — so a library of songs persists as plain JSON and a
/// future Watch app can reuse it verbatim.
struct Song: Identifiable, Equatable, Codable {
    /// Master tempo multiplier applied to EVERY section at playback (1.0 = each section's own BPM). A
    /// **non-destructive** control: it scales the whole song up/down while preserving the ratio between
    /// sections (a half-time bridge stays half-time), and the per-section BPMs are never rewritten. Clamped
    /// to a sane practice range.
    static let tempoScaleRange: ClosedRange<Double> = 0.5...2.0

    var id: UUID
    var name: String
    var sections: [SongSection]
    /// See `tempoScaleRange`. Default 1.0; persisted with the song.
    var tempoScale: Double
    /// Optional pickup (anacrusis) at the very START of the song, in the FIRST section's grid ticks (0 =
    /// none, the default). Like a section pickup it is a one-time lead-in before the song's first downbeat;
    /// floored at 0 here and re-clamped to the first section's grid at playback via `Pickup.effectiveTicks`.
    /// Persisted with the song; tolerated-if-missing so pre-pickup songs decode unchanged.
    var pickupTicks: Int

    init(id: UUID = UUID(), name: String = "Untitled Song", sections: [SongSection] = [],
         tempoScale: Double = 1.0, pickupTicks: Int = 0) {
        self.id = id
        self.name = name
        self.sections = sections
        self.tempoScale = tempoScale.clamped(to: Song.tempoScaleRange)
        self.pickupTicks = max(0, pickupTicks)
    }

    enum CodingKeys: String, CodingKey { case id, name, sections, tempoScale, pickupTicks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Song"
        self.sections = try c.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
        // Tolerate pre-scale song files (missing key → 1.0) and clamp hostile values.
        self.tempoScale = (try c.decodeIfPresent(Double.self, forKey: .tempoScale) ?? 1.0)
            .clamped(to: Song.tempoScaleRange)
        // Default 0 (no pickup) when absent — a song saved/exported before this field decodes as before.
        self.pickupTicks = max(0, try c.decodeIfPresent(Int.self, forKey: .pickupTicks) ?? 0)
    }

    /// Total bars across every section (each section's bars × repeats).
    var totalBars: Int { sections.reduce(0) { $0 + $1.totalBars } }
    var isEmpty: Bool { sections.isEmpty }

    /// Total duration in seconds at the CURRENT master tempo scale (faster scale ⇒ shorter). The section
    /// sum is `totalTicks × secondsPerTick` at each section's own BPM, divided by the scale.
    var durationSeconds: Double {
        let base = sections.reduce(0) { $0 + Double($1.totalTicks) * $1.secondsPerTick }
        return tempoScale > 0 ? base / tempoScale : base
    }

    // MARK: - Master tempo scale (non-destructive)

    /// The resulting integer BPM of `sectionBPM` under the current master scale, rounded and clamped to the
    /// engine's valid tempo range — what actually plays / is shown.
    func resultingBPM(_ sectionBPM: Double) -> Int {
        Int((sectionBPM * tempoScale).clamped(to: MetronomeConfiguration.tempoRange).rounded())
    }

    /// A flattened copy for PLAYBACK: every section's BPM multiplied by the master scale (rounded/clamped),
    /// with the scale reset to 1.0. The stored song's per-section BPMs and `tempoScale` are untouched — this
    /// is a transient value the engine plays, so scaling is fully non-destructive. Identity is preserved.
    func playbackScaled() -> Song {
        guard tempoScale != 1.0 else { return self }
        let scaled = sections.map { s in
            SongSection(id: s.id, name: s.name, tempoBPM: (s.tempoBPM * tempoScale).rounded(),
                        timeSignature: s.timeSignature, subdivision: s.subdivision,
                        accentPattern: s.accentPattern, bars: s.bars, repeatCount: s.repeatCount,
                        swing: s.swing, cell: s.cell, pickupTicks: s.pickupTicks)
        }
        return Song(id: id, name: name, sections: scaled, tempoScale: 1.0, pickupTicks: pickupTicks)
    }
}
