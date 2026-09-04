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
    /// Main beats (pulses) per bar — `timeSignature.beatsPerBar` (2 for 6/8, etc.). Named `beatsPerBar`,
    /// not `numerator`, because a compound meter pulses on its dotted-quarter beats, not its eighths.
    let beatsPerBar: Int
    let accents: [BeatAccent]
    let sampleRate: Double
    /// Frames between consecutive clicks: `secondsPerTick × sampleRate`. May be fractional.
    let framesPerTick: Double

    init(config: MetronomeConfiguration, sampleRate: Double) {
        self.ticksPerBeat = config.ticksPerBeat
        self.beatsPerBar = config.beatsPerBar
        self.accents = config.accents
        self.sampleRate = sampleRate
        self.framesPerTick = config.secondsPerTick * sampleRate
    }

    /// Absolute frame index (from playback start) of tick `n` — closed form, zero cumulative drift.
    @inline(__always)
    func frame(forTick n: Int) -> Int {
        Int((Double(n) * framesPerTick).rounded())
    }

    /// Emphasis of tick `n` (global tick index from playback start). A muted beat silences its whole span
    /// (on-beat click and its subdivisions); the engine still publishes the pulse for it.
    @inline(__always)
    func accentLevel(forTick n: Int) -> AccentLevel {
        let beat = (n / ticksPerBeat) % beatsPerBar
        let beatAccent = accents.indices.contains(beat) ? accents[beat] : .normal
        if beatAccent == .muted { return .muted }
        guard n % ticksPerBeat == 0 else { return .weak }
        return beatAccent.audioLevel
    }

    /// Beat index within the bar for tick `n`, or `nil` if `n` is a subdivision click.
    @inline(__always)
    func beatIndex(forTick n: Int) -> Int? {
        guard n % ticksPerBeat == 0 else { return nil }
        return (n / ticksPerBeat) % beatsPerBar
    }

    /// The Voice token for tick `n` (global tick from playback start) — which spoken number or syllable
    /// (or none → click) the Voice sound should utter, following standard Western counting:
    ///   * eighths    → "1 and 2 and …"
    ///   * sixteenths → "1 e and a 2 e and a …"
    ///   * triplets   → "1 trip let 2 trip let …"
    ///   * compound meters (6/8, 9/8, 12/8) with the eighth pulse → each dotted-quarter beat divides in
    ///     three, so this is exactly the triplet case: the beat speaks its ordinal ("1", "2", …) and the
    ///     two inner eighths speak "trip"/"let". (With the main-beat-only subdivision it just counts the
    ///     beats "1 2 …".) No special-casing is needed — the compound-aware `ticksPerBeat`/`beatsPerBar`
    ///     make the generic rules below produce the right count.
    ///   * 32nds and any unmapped subdivision → the beat speaks its number; the in-between ticks click.
    @inline(__always)
    func voiceToken(forTick n: Int) -> VoiceToken {
        let tpb = ticksPerBeat
        let posInBeat = n % tpb
        if posInBeat == 0 {
            let beat = (n / tpb) % beatsPerBar
            return .number(beat)
        }
        switch tpb {
        case 2:  return .syllable(.and)                              // eighth off-beat
        case 3:  return .syllable(posInBeat == 1 ? .trip : .letSub)  // triplet inner pulses
        case 4:                                                      // sixteenth inner pulses
            switch posInBeat {
            case 1:  return .syllable(.e)
            case 2:  return .syllable(.and)
            default: return .syllable(.a)
            }
        default: return .none                                       // 32nd (and beyond): click between
        }
    }
}
