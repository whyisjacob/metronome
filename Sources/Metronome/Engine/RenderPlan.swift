import Foundation

/// An immutable snapshot of the time-varying render parameters, published to the audio thread by
/// atomic reference swap (see `MetronomeEngine`). It carries **no audio data** — the click-buffer
/// table is immutable and owned by the engine — only the timing grid and accent pattern, so building
/// and swapping a plan is cheap and the audio thread only ever reads it.
///
/// The frame math here is intentionally identical to `MetronomeConfiguration.frame(forTick:)` so the
/// value proven correct by the pure-math unit tests is the exact value the audio render path uses.
final class RenderPlan {
    let ticksPerBeat: Int
    let numerator: Int
    let accents: [Bool]
    let sampleRate: Double
    /// Frames between consecutive clicks: `secondsPerTick × sampleRate`. May be fractional.
    let framesPerTick: Double

    init(config: MetronomeConfiguration, sampleRate: Double) {
        self.ticksPerBeat = config.ticksPerBeat
        self.numerator = config.timeSignature.numerator
        self.accents = config.accents
        self.sampleRate = sampleRate
        self.framesPerTick = config.secondsPerTick * sampleRate
    }

    /// Absolute frame index (from playback start) of tick `n` — closed form, zero cumulative drift.
    @inline(__always)
    func frame(forTick n: Int) -> Int {
        Int((Double(n) * framesPerTick).rounded())
    }

    /// Emphasis of tick `n` (global tick index from playback start).
    @inline(__always)
    func accentLevel(forTick n: Int) -> AccentLevel {
        guard n % ticksPerBeat == 0 else { return .weak }
        let beat = (n / ticksPerBeat) % numerator
        return (accents.indices.contains(beat) && accents[beat]) ? .strong : .normal
    }

    /// Beat index within the bar for tick `n`, or `nil` if `n` is a subdivision click.
    @inline(__always)
    func beatIndex(forTick n: Int) -> Int? {
        guard n % ticksPerBeat == 0 else { return nil }
        return (n / ticksPerBeat) % numerator
    }
}
