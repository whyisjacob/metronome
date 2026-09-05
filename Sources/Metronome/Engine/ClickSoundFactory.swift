import Foundation

/// Generates the metronome's click sounds in code — no audio assets required.
///
/// Each click is a short enveloped tone. Using a **cosine** carrier (not sine) means the very first
/// sample is the click's peak: it gives a crisp percussive attack *and* makes the onset land exactly
/// on sample 0 of the buffer, which is what lets the offline accuracy test detect onsets to the
/// sample. The set is a table keyed by `AccentLevel`, and the per-`MetronomeSound` spec sets below keep
/// it structured so more timbres can be added without touching the engine.
///
/// > The `.classic` voice is intentionally left bit-for-bit identical to the original single-timbre
/// > click (a `Spec` at its defaults reduces to the original formula), so the accuracy tests — which
/// > always drive `.classic` — see exactly the same audio they always have.
enum ClickSoundFactory {

    /// One generated click voice. The first three fields are the original parameters; the rest default
    /// to "off", so a bare `Spec(frequency:durationSeconds:gain:)` renders the original classic click.
    struct Spec {
        var frequency: Double        // Hz (carrier)
        var durationSeconds: Double
        var gain: Double             // 0...1 peak amplitude
        /// dB of exponential decay across the whole buffer (60 ≈ the original ~-60 dB tail).
        var decayDB: Double = 60
        /// Frequency multiplier for an added partial (0 = none) — gives woodblock/cowbell their timbre.
        var partialRatio: Double = 0
        /// Relative amplitude of that partial.
        var partialGain: Double = 0
        /// Relative amplitude of a decaying noise burst (0 = none) — the snap in a rimshot.
        var noiseGain: Double = 0
        /// Hard-clip the carrier toward a square wave for extra bite (beep/cowbell).
        var square: Bool = false
    }

    // MARK: - Per-sound voice sets (strong / normal / weak)

    /// The original v1 voice set. Bright "tock" for accents, mid "tick" for beats, soft low click for
    /// subdivisions. Unchanged — the accuracy tests depend on this exact timbre.
    static let defaultSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 2093, durationSeconds: 0.016, gain: 1.00),   // C7
        .normal: Spec(frequency: 1568, durationSeconds: 0.013, gain: 0.72),   // G6
        .weak:   Spec(frequency: 1319, durationSeconds: 0.009, gain: 0.42),   // E6
    ]

    private static let woodblockSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 1750, durationSeconds: 0.030, gain: 0.70, decayDB: 55, partialRatio: 2.05, partialGain: 0.45),
        .normal: Spec(frequency: 1500, durationSeconds: 0.026, gain: 0.52, decayDB: 55, partialRatio: 2.05, partialGain: 0.40),
        .weak:   Spec(frequency: 1300, durationSeconds: 0.020, gain: 0.34, decayDB: 55, partialRatio: 2.05, partialGain: 0.35),
    ]

    private static let beepSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 1760, durationSeconds: 0.055, gain: 0.55, decayDB: 22, square: true),
        .normal: Spec(frequency: 1318, durationSeconds: 0.050, gain: 0.42, decayDB: 22, square: true),
        .weak:   Spec(frequency: 1046, durationSeconds: 0.038, gain: 0.30, decayDB: 26, square: true),
    ]

    private static let rimshotSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 420, durationSeconds: 0.028, gain: 0.55, decayDB: 60, partialRatio: 3.2, partialGain: 0.30, noiseGain: 0.60),
        .normal: Spec(frequency: 380, durationSeconds: 0.024, gain: 0.44, decayDB: 60, partialRatio: 3.2, partialGain: 0.25, noiseGain: 0.50),
        .weak:   Spec(frequency: 330, durationSeconds: 0.018, gain: 0.32, decayDB: 62, partialRatio: 3.2, partialGain: 0.20, noiseGain: 0.40),
    ]

    private static let cowbellSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 560, durationSeconds: 0.090, gain: 0.52, decayDB: 34, partialRatio: 1.5, partialGain: 0.70, square: true),
        .normal: Spec(frequency: 540, durationSeconds: 0.075, gain: 0.40, decayDB: 34, partialRatio: 1.5, partialGain: 0.60, square: true),
        .weak:   Spec(frequency: 520, durationSeconds: 0.055, gain: 0.28, decayDB: 36, partialRatio: 1.5, partialGain: 0.50, square: true),
    ]

    /// The voice set for a sound. `.voice` has no click timbre of its own — it falls back to the classic
    /// click for subdivision ticks and while its spoken buffers are still rendering.
    ///
    /// A `.medium` (secondary-accent) spec is derived automatically as the mid-point between the sound's
    /// `.strong` and `.normal` specs, so every timbre gains a distinct in-between click with no per-sound
    /// tuning — and, crucially, without disturbing the `.strong`/`.normal`/`.weak` specs the accuracy
    /// tests render against.
    static func specs(for sound: MetronomeSound) -> [AccentLevel: Spec] {
        let base: [AccentLevel: Spec]
        switch sound {
        case .classic, .voice: base = defaultSpecs
        case .woodblock:       base = woodblockSpecs
        case .beep:            base = beepSpecs
        case .rimshot:         base = rimshotSpecs
        case .cowbell:         base = cowbellSpecs
        }
        var withMedium = base
        if let s = base[.strong], let n = base[.normal] {
            withMedium[.medium] = mediumSpec(strong: s, normal: n)
        }
        return withMedium
    }

    /// The **pickup / count-in** click voice for one accent level: the sound's own click for that level,
    /// dropped a perfect fifth in pitch. The lower pitch makes it audibly DISTINCT from both the strong
    /// downbeat and the normal beat ("a slightly different tune") — a lead-in that reads as a lead-in — at
    /// the level's OWN gain (never louder), so a pickup that spans a group head keeps its `medium` emphasis.
    static func pickupSpec(_ spec: Spec) -> Spec {
        var s = spec
        s.frequency = spec.frequency * (2.0 / 3.0)   // a perfect fifth below the normal pitch
        return s
    }

    /// The full pickup click table for `sound` — one buffer per `AccentLevel`, the same accent-indexed
    /// structure as `makeClickTable` but pitch-shifted (see `pickupSpec`). Because the pickup ticks reuse
    /// the bar's real tail accents, indexing this by the tick's natural level preserves the pickup's
    /// internal emphasis (e.g. a 7/8 group head stays `medium`) while giving the whole lead-in a distinct
    /// timbre. The `.muted` slot is empty (as in `makeClickTable`) and `.strong` is never triggered for a
    /// pickup (a tail tick is never the downbeat).
    static func makePickupTable(sampleRate: Double, sound: MetronomeSound = .classic) -> [[Float]] {
        let shifted = specs(for: sound).mapValues(pickupSpec)
        return makeClickTable(sampleRate: sampleRate, specs: shifted)
    }

    /// The secondary-accent voice: field-wise mid-point between the strong and normal specs. Its timbre
    /// (partial ratio, square, noise) follows `normal` so it shares the sound's character; only the
    /// magnitude/brightness sit between the two, giving a clearly audible in-between click.
    static func mediumSpec(strong s: Spec, normal n: Spec) -> Spec {
        func mid(_ a: Double, _ b: Double) -> Double { (a + b) / 2 }
        return Spec(frequency: mid(s.frequency, n.frequency),
                    durationSeconds: mid(s.durationSeconds, n.durationSeconds),
                    gain: mid(s.gain, n.gain),
                    decayDB: mid(s.decayDB, n.decayDB),
                    partialRatio: n.partialRatio,
                    partialGain: mid(s.partialGain, n.partialGain),
                    noiseGain: mid(s.noiseGain, n.noiseGain),
                    square: n.square)
    }

    // MARK: - Table building

    /// Builds one click buffer per `AccentLevel` for `sound`, indexed by `AccentLevel.rawValue`
    /// (0 = strong, 1 = normal, 2 = weak, 3 = medium, 4 = muted). Generated once per sample rate / sound
    /// and then treated as immutable, so the audio thread can read it lock-free.
    static func makeClickTable(sampleRate: Double, sound: MetronomeSound = .classic) -> [[Float]] {
        makeClickTable(sampleRate: sampleRate, specs: specs(for: sound))
    }

    /// Builds a click table from an explicit spec set. The `.muted` slot is intentionally an **empty**
    /// buffer — the engine never triggers it (it suppresses the click for a muted beat) — so it costs
    /// nothing and can never make a sound.
    static func makeClickTable(sampleRate: Double,
                               specs: [AccentLevel: Spec]) -> [[Float]] {
        AccentLevel.allCases
            .sorted { $0.rawValue < $1.rawValue }
            .map { level in
                guard level != .muted else { return [] }
                return renderClick(specs[level] ?? defaultSpecs[.normal]!, sampleRate: sampleRate)
            }
    }

    /// Renders a single click to mono float samples. `buffer[0]` is the strict peak magnitude (cosine
    /// carrier), so a rising-edge detector finds the onset at exactly frame 0. With every optional field
    /// at its default (`partialRatio`/`noiseGain`/`square` off, `decayDB == 60`) this is bit-for-bit the
    /// original classic-click formula.
    static func renderClick(_ spec: Spec, sampleRate: Double) -> [Float] {
        let count = max(1, Int(spec.durationSeconds * sampleRate))
        var buffer = [Float](repeating: 0, count: count)
        // Exponential decay reaching about `-decayDB` by the final sample. For decayDB == 60 this is
        // log(1000)/count, i.e. the original ~-60 dB tail, so truncation stays inaudible.
        let decay = (spec.decayDB / 20.0) * log(10.0) / Double(count)
        let omega = 2.0 * Double.pi * spec.frequency / sampleRate
        let omega2 = omega * spec.partialRatio

        // Deterministic tiny PRNG (xorshift64) for the rimshot noise burst — no Foundation RNG, and
        // deterministic so a sound never changes between renders. Unused when noiseGain == 0.
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func nextNoise() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(Int64(bitPattern: rng)) / Double(Int64.max)   // ~ -1...1
        }

        for i in 0..<count {
            let envelope = exp(-Double(i) * decay)
            var s = cos(omega * Double(i))
            if spec.square { s = s >= 0 ? 1.0 : -1.0 }
            if spec.partialRatio > 0 { s += spec.partialGain * cos(omega2 * Double(i)) }
            if spec.noiseGain > 0 { s += spec.noiseGain * nextNoise() }
            buffer[i] = Float(s * envelope * spec.gain)
        }
        return buffer
    }
}
