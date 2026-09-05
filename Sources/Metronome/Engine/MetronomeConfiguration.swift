import Foundation

/// The complete, value-type description of what the metronome should sound like: tempo, meter,
/// subdivision, and per-beat accents. It is `Equatable`/`Codable` and free of any audio or UI
/// types, so it is trivial to test and to persist, and a future Watch app can reuse it verbatim.
///
/// All click-timing math lives here (`frame(forTick:)`, `accentLevel(forTick:)`) so it can be unit
/// tested directly, independently of AVAudioEngine.
struct MetronomeConfiguration: Equatable, Codable {
    static let tempoRange: ClosedRange<Double> = 30...300
    /// Swing amount: `0` = straight, `1` = full triplet swing. Clamped to this range.
    static let swingRange: ClosedRange<Double> = 0...1

    /// Beats (pulses) per minute — quarter notes in a simple meter, **dotted quarters** in a compound
    /// one. Clamped to `tempoRange`.
    var bpm: Double
    var timeSignature: TimeSignature
    var subdivision: Subdivision
    /// One `BeatAccent` per main beat (`count == timeSignature.beatsPerBar`).
    var accents: [BeatAccent]
    /// The click timbre, or the spoken-number Voice mode. Purely a sound choice — it has no effect on
    /// timing, so `RenderPlan`/`SongPlan` ignore it; only the engine's buffer selection consults it.
    var sound: MetronomeSound
    /// Swing / shuffle amount (`0`…`1`). Delays the off-beat members of eighth (and sixteenth) pairs from
    /// ½ toward ⅔ of the pair; the main beats never move. `0` (the default) keeps a perfectly straight,
    /// byte-for-byte unchanged grid. See `SwingGrid`.
    var swing: Double
    /// A preset idiomatic rhythm cell on the sixteenth grid (silences some sub-positions). `.straight`
    /// (the default) sounds every sixteenth. Applies only when `subdivision == .sixteenth`. See `RhythmCell`.
    var cell: RhythmCell

    init(bpm: Double = 120,
         timeSignature: TimeSignature = .common,
         subdivision: Subdivision = .quarter,
         accents: [BeatAccent]? = nil,
         sound: MetronomeSound = .classic,
         swing: Double = 0,
         cell: RhythmCell = .straight) {
        self.bpm = bpm.clamped(to: Self.tempoRange)
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.sound = sound
        self.swing = swing.clamped(to: Self.swingRange)
        self.cell = cell
        // With no explicit accents, adopt the meter's sensible default (downbeat + secondary group-head
        // accents for simple meters, every dotted-quarter group head for compound 6/8-style meters).
        self.accents = MetronomeConfiguration.normalizedAccents(accents ?? timeSignature.defaultAccents,
                                                                count: timeSignature.beatsPerBar)
    }

    // Decode through the validating initializer (clamps bpm/swing, re-sizes accents) and tolerate missing
    // keys (`sound`, `swing`, `cell`) so older/persisted configs still load — a pre-swing recent decodes
    // as straight. `BeatAccent` decoding also accepts the legacy `[Bool]` accent form. Encoding stays
    // synthesized from `CodingKeys`.
    enum CodingKeys: String, CodingKey { case bpm, timeSignature, subdivision, accents, sound, swing, cell }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        let ts = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? .common
        let sub = try c.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .quarter
        let accents = try c.decodeIfPresent([BeatAccent].self, forKey: .accents)
        let sound = try c.decodeIfPresent(MetronomeSound.self, forKey: .sound) ?? .classic
        let swing = try c.decodeIfPresent(Double.self, forKey: .swing) ?? 0
        let cell = try c.decodeIfPresent(RhythmCell.self, forKey: .cell) ?? .straight
        self.init(bpm: bpm, timeSignature: ts, subdivision: sub, accents: accents, sound: sound,
                  swing: swing, cell: cell)
    }

    // MARK: - Derived timing

    /// Seconds per main beat (a quarter in a simple meter, a dotted quarter in a compound one).
    var secondsPerBeat: Double { 60.0 / bpm }
    /// Main beats (pulses) per bar.
    var beatsPerBar: Int { timeSignature.beatsPerBar }
    /// Clicks per main beat — compound-aware (a compound beat divides into 3 eighths, not 2).
    var ticksPerBeat: Int { subdivision.ticksPerBeat(compound: timeSignature.isCompound) }
    /// Seconds between two consecutive clicks (beats *and* subdivisions).
    var secondsPerTick: Double { secondsPerBeat / Double(ticksPerBeat) }
    /// Total clicks in one bar.
    var ticksPerBar: Int { ticksPerBeat * beatsPerBar }

    // MARK: - Groove activation state

    /// Whether swing can actually be *heard* at the current subdivision, as opposed to merely being set.
    /// Swing only displaces the off-beat members of eighth/sixteenth pairs (`SwingGrid.swings`), so at a
    /// quarter, triplet, tuplet or compound-eighth grid a non-zero `swing` is inert. The UI reads this to
    /// tell the truth — it never labels playback "swung" while the grid renders it straight.
    var swingIsAudible: Bool { swing > 0 && SwingGrid.swings(ticksPerBeat: ticksPerBeat) }

    /// Whether the selected rhythm cell can actually apply. Cells silence sub-positions of the **sixteenth**
    /// grid only (`RhythmCell.silences` requires `ticksPerBeat == 4`), so a cell is inert on any other grid.
    var cellIsActive: Bool { cell != .straight && ticksPerBeat == 4 }

    /// Frames between consecutive clicks at `sampleRate` (may be fractional).
    func framesPerTick(sampleRate: Double) -> Double {
        secondsPerTick * sampleRate
    }

    /// Absolute frame index (measured from playback start, frame 0) of tick `n` at `sampleRate`.
    ///
    /// Deliberately a **closed form** — `round(n × framesPerTick)` — never an accumulation of
    /// per-tick durations, so the placed grid cannot drift: the error versus the ideal continuous
    /// time is bounded by ±0.5 sample for *every* n and never compounds.
    ///
    /// The grouping (`framesPerTick = secondsPerTick × sampleRate`, then `× n`) is deliberately
    /// identical to `RenderPlan.frame(forTick:)` so the audio render path places onsets on exactly
    /// the frames this pure function predicts — floating-point multiplication is not associative, so
    /// the two must group the operands the same way.
    ///
    /// Swing (when `swing > 0` on an eighth/sixteenth subdivision) shifts the off-beat pair members via
    /// the shared `SwingGrid`; at `swing == 0` it is exactly the closed form above, unchanged.
    func frame(forTick n: Int, sampleRate: Double) -> Int {
        SwingGrid.frame(forTick: n, ticksPerBeat: ticksPerBeat,
                        framesPerTick: framesPerTick(sampleRate: sampleRate), swing: swing)
    }

    /// The emphasis of tick `n` (a global tick index counted from playback start).
    ///
    /// A **muted** beat suppresses its whole span — the on-beat click *and* the subdivisions inside it —
    /// so the beat is genuinely silent; the engine still publishes the pulse so the count/visual advance.
    ///
    /// An idiomatic **cell** (sixteenth grid only) silences the sub-positions it does not sound, reusing
    /// the same `.muted` path so those ticks are silent but still advance the count. Position 0 keeps the
    /// beat's accent, so the cell's downbeat is emphasised over its inner sixteenths.
    func accentLevel(forTick n: Int) -> AccentLevel {
        let tpb = ticksPerBeat
        let beat = beatIndexWithinBar(n / tpb)
        let beatAccent = accents.indices.contains(beat) ? accents[beat] : .normal
        if beatAccent == .muted { return .muted }             // whole beat (incl. subdivisions) silent
        let pos = n % tpb
        if cell.silences(posInBeat: pos, ticksPerBeat: tpb) { return .muted }   // cell-silenced sub-position
        guard pos == 0 else { return .weak }                  // between beats → subdivision click
        return beatAccent.audioLevel                          // strong / medium / normal
    }

    /// Beat index within the bar (0-based) for tick `n`, or `nil` if `n` is a subdivision click.
    func beatIndex(forTick n: Int) -> Int? {
        let tpb = ticksPerBeat
        guard n % tpb == 0 else { return nil }
        return beatIndexWithinBar(n / tpb)
    }

    private func beatIndexWithinBar(_ globalBeat: Int) -> Int {
        let beats = max(beatsPerBar, 1)
        // Swift's % can be negative; tick indices are non-negative so this is safe, but keep it
        // defensive for reuse.
        let m = globalBeat % beats
        return m >= 0 ? m : m + beats
    }

    // MARK: - Accent helpers

    /// Advances the accent of beat `index` to the next state in the tap-to-cycle order
    /// (strong → medium → normal → muted → strong), returning a new configuration.
    func cyclingAccent(at index: Int) -> MetronomeConfiguration {
        guard accents.indices.contains(index) else { return self }
        var copy = self
        copy.accents[index] = copy.accents[index].next
        return copy
    }

    /// Ensures the accent array matches `count`, padding with `.normal` and truncating as needed. When a
    /// pattern is entirely `.normal` (no emphasis at all), the downbeat is promoted to `.strong` so a bar
    /// is never accent-less by omission; explicit `.muted`/`.medium` choices are always respected, so a
    /// deliberately all-muted (silent) bar is allowed.
    static func normalizedAccents(_ accents: [BeatAccent]?, count: Int) -> [BeatAccent] {
        var result = accents ?? []
        if result.count < count {
            result += Array(repeating: .normal, count: count - result.count)
        } else if result.count > count {
            result = Array(result.prefix(count))
        }
        if !result.isEmpty && result.allSatisfy({ $0 == .normal }) {
            result[0] = .strong
        }
        return result
    }

    /// Returns a copy re-normalized so `accents.count == beatsPerBar` after a meter change.
    func normalizingAccents() -> MetronomeConfiguration {
        var copy = self
        copy.accents = MetronomeConfiguration.normalizedAccents(accents, count: timeSignature.beatsPerBar)
        return copy
    }

    // MARK: - Recents identity

    /// The uniqueness key for the Recents feature: **everything except tempo**. Two configurations that
    /// differ only in `bpm` share a key (so a BPM-only change updates the same recent in place), while a
    /// change to meter, subdivision, accents, or sound yields a distinct key (a new/re-surfaced recent).
    var settingsKey: SettingsKey {
        SettingsKey(numerator: timeSignature.numerator,
                    denominator: timeSignature.denominator,
                    subdivision: subdivision,
                    accents: accents,
                    sound: sound)
    }
}

/// A tempo-independent identity for a metronome configuration — see `MetronomeConfiguration.settingsKey`.
struct SettingsKey: Equatable, Hashable, Codable {
    var numerator: Int
    var denominator: Int
    var subdivision: Subdivision
    var accents: [BeatAccent]
    var sound: MetronomeSound
}
