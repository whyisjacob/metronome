import Foundation

/// One contiguous stretch of a piece that keeps a single tempo, meter, subdivision and accent
/// pattern for a whole number of bars — the building block of a `Song` tempo-map.
///
/// A section is a pure value type (like `MetronomeConfiguration`), free of any audio/UI types, so it
/// is trivial to test and to persist. All of its timing math is derived (`secondsPerTick`,
/// `totalTicks`, …) and is the *only* per-section source the sequencer (`SongPlan`) consults, so the
/// numbers proven correct here are exactly the numbers the audio path uses.
///
/// It is named `SongSection` (not `Section`) deliberately: SwiftUI already exports a `Section` view,
/// and the two are used side-by-side in the builder UI.
struct SongSection: Identifiable, Equatable, Codable {

    /// Measures (bars) allowed in a single section. Generous upper bound; the UI steppers stay well
    /// under it. `1` is the floor so a section always contributes at least one bar of clicks.
    static let barsRange = 1...512
    /// How many times the section's bars repeat. `1` == play once.
    static let repeatRange = 1...64

    /// Stable identity for SwiftUI lists / reordering and for `SongStore` upserts. Survives Codable
    /// round-trips (a `UUID` is `Codable`).
    var id: UUID
    var name: String
    /// Beats (pulses) per minute for this section — quarter notes in a simple meter, dotted quarters in a
    /// compound one. Clamped to `MetronomeConfiguration.tempoRange`.
    var tempoBPM: Double
    var timeSignature: TimeSignature
    var subdivision: Subdivision
    /// One `BeatAccent` per main beat (`count == timeSignature.beatsPerBar`). Normalized so the downbeat
    /// is never accent-less by omission (reuses the single-tempo engine's rule).
    var accentPattern: [BeatAccent]
    /// Measures in one pass of the section (≥1).
    var bars: Int
    /// Number of passes (≥1). The bars play `repeatCount` times back-to-back.
    var repeatCount: Int
    /// Swing / shuffle amount (`0`…`1`) for this section — same model as `MetronomeConfiguration.swing`.
    /// `0` (the default) keeps the section perfectly straight. Applied by `SongPlan` via the shared
    /// `SwingGrid`, so a section's groove is bit-for-bit the single-tempo feel.
    var swing: Double
    /// A preset idiomatic rhythm cell on the sixteenth grid — same model as `MetronomeConfiguration.cell`.
    /// `.straight` (the default) sounds every sixteenth.
    var cell: RhythmCell

    init(id: UUID = UUID(),
         name: String = "Section",
         tempoBPM: Double = 120,
         timeSignature: TimeSignature = .common,
         subdivision: Subdivision = .quarter,
         accentPattern: [BeatAccent]? = nil,
         bars: Int = 1,
         repeatCount: Int = 1,
         swing: Double = 0,
         cell: RhythmCell = .straight) {
        self.id = id
        self.name = name
        self.tempoBPM = tempoBPM.clamped(to: MetronomeConfiguration.tempoRange)
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.bars = bars.clamped(to: SongSection.barsRange)
        self.repeatCount = repeatCount.clamped(to: SongSection.repeatRange)
        self.swing = swing.clamped(to: MetronomeConfiguration.swingRange)
        self.cell = cell
        // With no explicit pattern, adopt the meter's sensible default (downbeat + secondary group-head
        // accents), matching the single-tempo engine so a 6/8 section is felt in 2 by default.
        self.accentPattern = MetronomeConfiguration.normalizedAccents(accentPattern ?? timeSignature.defaultAccents,
                                                                      count: timeSignature.beatsPerBar)
    }

    // Decode through the validating initializer so a hand-edited or older JSON file can never load an
    // out-of-range tempo, a zero bar/repeat count, or a mis-sized accent array. `swing`/`cell` are
    // tolerated-if-missing so pre-groove song files still load (as straight).
    enum CodingKeys: String, CodingKey {
        case id, name, tempoBPM, timeSignature, subdivision, accentPattern, bars, repeatCount, swing, cell
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Section"
        let bpm = try c.decodeIfPresent(Double.self, forKey: .tempoBPM) ?? 120
        let ts = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? .common
        let sub = try c.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .quarter
        let accents = try c.decodeIfPresent([BeatAccent].self, forKey: .accentPattern)
        let bars = try c.decodeIfPresent(Int.self, forKey: .bars) ?? 1
        let repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        let swing = try c.decodeIfPresent(Double.self, forKey: .swing) ?? 0
        let cell = try c.decodeIfPresent(RhythmCell.self, forKey: .cell) ?? .straight
        self.init(id: id, name: name, tempoBPM: bpm, timeSignature: ts, subdivision: sub,
                  accentPattern: accents, bars: bars, repeatCount: repeatCount, swing: swing, cell: cell)
    }

    // MARK: - Derived timing (mirrors MetronomeConfiguration for a single section)

    /// Clicks per main beat — compound-aware (a compound dotted-quarter beat divides into 3 eighths).
    var ticksPerBeat: Int { subdivision.ticksPerBeat(compound: timeSignature.isCompound) }
    /// Main beats (pulses) per bar (2 for 6/8, etc.).
    var beatsPerBar: Int { timeSignature.beatsPerBar }
    /// Clicks in one bar.
    var ticksPerBar: Int { ticksPerBeat * beatsPerBar }
    /// Bars actually played (one pass × repeats).
    var totalBars: Int { bars * repeatCount }
    /// Clicks in the whole section (every bar of every repeat).
    var totalTicks: Int { ticksPerBar * totalBars }

    var secondsPerBeat: Double { 60.0 / tempoBPM }
    /// Seconds between two consecutive clicks. Grouped identically to `MetronomeConfiguration` so the
    /// value is bit-for-bit the same as the single-tempo path for the same tempo/subdivision.
    var secondsPerTick: Double { secondsPerBeat / Double(ticksPerBeat) }

    /// Frames between consecutive clicks at `sampleRate` (may be fractional). Grouped as
    /// `secondsPerTick × sampleRate`, exactly like `RenderPlan.framesPerTick`.
    func framesPerTick(sampleRate: Double) -> Double { secondsPerTick * sampleRate }

    // MARK: - Display helpers

    var meterAndFeel: String { "\(timeSignature.displayString) · \(subdivision.displayName)" }
    var barsSummary: String { repeatCount > 1 ? "\(bars) bars ×\(repeatCount)" : "\(bars) bar\(bars == 1 ? "" : "s")" }
    var tempoSummary: String { "\(Int(tempoBPM.rounded())) BPM" }
}
