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
    /// Whether the meter is compound (6/8, 9/8, 12/8): affects Voice counting, not timing.
    let isCompound: Bool

    init(config: MetronomeConfiguration, sampleRate: Double) {
        self.ticksPerBeat = config.ticksPerBeat
        self.numerator = config.timeSignature.numerator
        self.accents = config.accents
        self.sampleRate = sampleRate
        self.framesPerTick = config.secondsPerTick * sampleRate
        self.isCompound = config.timeSignature.isCompound
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

    /// The Voice token for tick `n` (global tick from playback start) — which spoken number or syllable
    /// (or none → click) the Voice sound should utter, following standard Western counting:
    ///   * eighths    → "1 and 2 and …"
    ///   * sixteenths → "1 e and a 2 e and a …"
    ///   * triplets   → "1 trip let 2 trip let …"
    ///   * compound meters (6/8, 9/8, 12/8) at the base pulse → each dotted-quarter group is felt like a
    ///     triplet: the group head speaks its ordinal ("1", "2", …) and the two inner pulses speak
    ///     "trip"/"let", so the count reflects the grouping.
    ///   * 32nds and any unmapped subdivision → the beat speaks its number; the in-between ticks click.
    @inline(__always)
    func voiceToken(forTick n: Int) -> VoiceToken {
        let tpb = ticksPerBeat
        let posInBeat = n % tpb
        if posInBeat == 0 {
            let beat = (n / tpb) % numerator
            if isCompound && tpb == 1 {
                // Compound felt in groups of three pulses (base/quarter subdivision).
                switch beat % 3 {
                case 0:  return .number(beat / 3)     // group head → the group's ordinal (0-based)
                case 1:  return .syllable(.trip)
                default: return .syllable(.letSub)
                }
            }
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
