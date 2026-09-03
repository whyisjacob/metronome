import Foundation

/// Generates the metronome's click sounds in code — no audio assets required.
///
/// Each click is a short enveloped cosine tone. Using a **cosine** carrier (not sine) means the very
/// first sample is the click's peak: it gives a crisp percussive attack *and* makes the onset land
/// exactly on sample 0 of the buffer, which is what lets the offline accuracy test detect onsets to
/// the sample. The set is a simple table keyed by `AccentLevel`, structured so more voices/timbres
/// can be added later without touching the engine.
enum ClickSoundFactory {

    /// One generated click voice.
    struct Spec {
        var frequency: Double        // Hz
        var durationSeconds: Double
        var gain: Double             // 0...1 peak amplitude
    }

    /// v1 default voice set. Bright "tock" for accents, mid "tick" for beats, soft low click for
    /// subdivisions.
    static let defaultSpecs: [AccentLevel: Spec] = [
        .strong: Spec(frequency: 2093, durationSeconds: 0.016, gain: 1.00),   // C7
        .normal: Spec(frequency: 1568, durationSeconds: 0.013, gain: 0.72),   // G6
        .weak:   Spec(frequency: 1319, durationSeconds: 0.009, gain: 0.42),   // E6
    ]

    /// Builds one click buffer per `AccentLevel`, indexed by `AccentLevel.rawValue`
    /// (0 = strong, 1 = normal, 2 = weak). Generated once per sample rate and then treated as
    /// immutable, so the audio thread can read it lock-free.
    static func makeClickTable(sampleRate: Double,
                               specs: [AccentLevel: Spec] = defaultSpecs) -> [[Float]] {
        AccentLevel.allCases
            .sorted { $0.rawValue < $1.rawValue }
            .map { level in
                renderClick(specs[level] ?? defaultSpecs[.normal]!, sampleRate: sampleRate)
            }
    }

    /// Renders a single click to mono float samples. `buffer[0]` is guaranteed to be the strict peak
    /// magnitude, so a rising-edge detector finds the onset at exactly frame 0.
    static func renderClick(_ spec: Spec, sampleRate: Double) -> [Float] {
        let count = max(1, Int(spec.durationSeconds * sampleRate))
        var buffer = [Float](repeating: 0, count: count)
        // Exponential decay reaching about -60 dB by the final sample, so truncation is inaudible.
        let decay = log(1000.0) / Double(count)
        let omega = 2.0 * Double.pi * spec.frequency / sampleRate
        for i in 0..<count {
            let envelope = exp(-Double(i) * decay)
            buffer[i] = Float(cos(omega * Double(i)) * envelope * spec.gain)
        }
        return buffer
    }
}
