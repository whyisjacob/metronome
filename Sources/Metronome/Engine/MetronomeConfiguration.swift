import Foundation

/// The complete, value-type description of what the metronome should sound like: tempo, meter,
/// subdivision, and per-beat accents. It is `Equatable`/`Codable` and free of any audio or UI
/// types, so it is trivial to test and to persist, and a future Watch app can reuse it verbatim.
///
/// All click-timing math lives here (`frame(forTick:)`, `accentLevel(forTick:)`) so it can be unit
/// tested directly, independently of AVAudioEngine.
struct MetronomeConfiguration: Equatable, Codable {
    static let tempoRange: ClosedRange<Double> = 30...300

    /// Beats (pulses) per minute. Clamped to `tempoRange`.
    var bpm: Double
    var timeSignature: TimeSignature
    var subdivision: Subdivision
    /// One flag per beat (`count == timeSignature.numerator`); `true` == accented.
    var accents: [Bool]
    /// The click timbre, or the spoken-number Voice mode. Purely a sound choice — it has no effect on
    /// timing, so `RenderPlan`/`SongPlan` ignore it; only the engine's buffer selection consults it.
    var sound: MetronomeSound

    init(bpm: Double = 120,
         timeSignature: TimeSignature = .common,
         subdivision: Subdivision = .quarter,
         accents: [Bool]? = nil,
         sound: MetronomeSound = .classic) {
        self.bpm = bpm.clamped(to: Self.tempoRange)
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.sound = sound
        self.accents = MetronomeConfiguration.normalizedAccents(accents, count: timeSignature.numerator)
    }

    // Decode through the validating initializer (clamps bpm, re-sizes accents) and tolerate a missing
    // `sound` key so older/persisted configs still load. Encoding stays synthesized from `CodingKeys`.
    enum CodingKeys: String, CodingKey { case bpm, timeSignature, subdivision, accents, sound }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 120
        let ts = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? .common
        let sub = try c.decodeIfPresent(Subdivision.self, forKey: .subdivision) ?? .quarter
        let accents = try c.decodeIfPresent([Bool].self, forKey: .accents)
        let sound = try c.decodeIfPresent(MetronomeSound.self, forKey: .sound) ?? .classic
        self.init(bpm: bpm, timeSignature: ts, subdivision: sub, accents: accents, sound: sound)
    }

    // MARK: - Derived timing

    var secondsPerBeat: Double { 60.0 / bpm }
    var ticksPerBeat: Int { subdivision.ticksPerBeat }
    /// Seconds between two consecutive clicks (beats *and* subdivisions).
    var secondsPerTick: Double { secondsPerBeat / Double(ticksPerBeat) }
    /// Total clicks in one bar.
    var ticksPerBar: Int { ticksPerBeat * timeSignature.numerator }

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
    func frame(forTick n: Int, sampleRate: Double) -> Int {
        Int((Double(n) * framesPerTick(sampleRate: sampleRate)).rounded())
    }

    /// The emphasis of tick `n` (a global tick index counted from playback start).
    func accentLevel(forTick n: Int) -> AccentLevel {
        let tpb = ticksPerBeat
        guard n % tpb == 0 else { return .weak }              // between beats → subdivision click
        let beat = beatIndexWithinBar(n / tpb)
        return (accents.indices.contains(beat) && accents[beat]) ? .strong : .normal
    }

    /// Beat index within the bar (0-based) for tick `n`, or `nil` if `n` is a subdivision click.
    func beatIndex(forTick n: Int) -> Int? {
        let tpb = ticksPerBeat
        guard n % tpb == 0 else { return nil }
        return beatIndexWithinBar(n / tpb)
    }

    private func beatIndexWithinBar(_ globalBeat: Int) -> Int {
        let numerator = timeSignature.numerator
        // Swift's % can be negative; tick indices are non-negative so this is safe, but keep it
        // defensive for reuse.
        let m = globalBeat % numerator
        return m >= 0 ? m : m + numerator
    }

    // MARK: - Accent helpers

    /// Toggles the accent of beat `index`, returning a new configuration.
    func togglingAccent(at index: Int) -> MetronomeConfiguration {
        guard accents.indices.contains(index) else { return self }
        var copy = self
        copy.accents[index].toggle()
        return copy
    }

    /// Ensures the accent array matches `count`, defaulting beat 0 accented and guaranteeing at
    /// least one accent so the downbeat is never silent-by-omission.
    static func normalizedAccents(_ accents: [Bool]?, count: Int) -> [Bool] {
        var result = accents ?? []
        if result.count < count {
            result += Array(repeating: false, count: count - result.count)
        } else if result.count > count {
            result = Array(result.prefix(count))
        }
        if !result.isEmpty && result.allSatisfy({ !$0 }) {
            result[0] = true
        }
        return result
    }

    /// Returns a copy re-normalized so `accents.count == numerator` after a meter change.
    func normalizingAccents() -> MetronomeConfiguration {
        var copy = self
        copy.accents = MetronomeConfiguration.normalizedAccents(accents, count: timeSignature.numerator)
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
    var accents: [Bool]
    var sound: MetronomeSound
}
