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
    /// Swing amount (`0`…`1`), applied to off-beat pair members via `SwingGrid`. `0` ⇒ a straight grid.
    let swing: Double
    /// Idiomatic sixteenth-grid cell; `.straight` ⇒ every sixteenth sounds.
    let cell: RhythmCell
    /// The gap-click trainer overlay. It changes only *which* beats sound, never *when* (see `GapTrainer`),
    /// so it is captured immutably here and consulted per tick by the audio thread. Disabled by default,
    /// which makes the whole plan behave byte-for-byte as before (the accuracy tests never enable it).
    let trainer: GapTrainer

    init(config: MetronomeConfiguration, sampleRate: Double, trainer: GapTrainer = GapTrainer()) {
        self.ticksPerBeat = config.ticksPerBeat
        self.beatsPerBar = config.beatsPerBar
        self.accents = config.accents
        self.sampleRate = sampleRate
        self.framesPerTick = config.secondsPerTick * sampleRate
        self.swing = config.swing
        self.cell = config.cell
        self.trainer = trainer
    }

    /// Seconds between two consecutive clicks (beats *and* subdivisions) — the inverse of the frame math.
    @inline(__always)
    var secondsPerTick: Double { sampleRate > 0 ? framesPerTick / sampleRate : 0 }

    /// Shortest subdivision interval (seconds) at which a *spoken* counting syllable still finishes before
    /// the next onset. It sits just above the longest spoken syllable ("and", hard-capped at 0.12 s by
    /// `VoiceSampleFactory.compactSyllable`), so a syllable scheduled on a tick this long always clears
    /// before the next tick — below it, that syllable would be hard-cut mid-word, so we click it instead.
    /// Measured from the bundled clips (see tools/measure_voice.py); 0.12 s syllable + ~0.02 s margin.
    static let minSpokenSubdivisionSeconds = 0.14

    /// How much of the count Voice mode *speaks* (vs clicks) at this tempo. The physical reality is that a
    /// sixteenth grid is 4 tokens/beat and each token has a floor length, so above some tempo they cannot
    /// all fit — rather than smear, we speak fewer of them as the tick shrinks. Beats ALWAYS speak their
    /// number; this only governs the in-between ticks.
    enum VoiceDetail: Equatable {
        /// Speak every mapped token — sixteenths say the full "1 e and a"; the tick fits a syllable.
        case full
        /// SIXTEENTHS only, middle tier: the sixteenth is too short for a token but the EIGHTH still fits,
        /// so speak the beat number and the "and" (the eighth positions) and CLICK the "e"/"a" → "1 . and .".
        case eighthsOnly
        /// Speak only the beat numbers and click every subdivision → "1 . . ." — even the eighth is too short
        /// (or the subdivision has no spoken syllable, e.g. a tuplet / 32nds).
        case beatsOnly
    }

    /// The speak-vs-click tier for the CURRENT tempo & subdivision (see `VoiceDetail`). Derived purely from
    /// the measured minimum spoken interval, so the threshold reflects the real bundled-clip lengths.
    @inline(__always)
    var voiceDetail: VoiceDetail {
        if ticksPerBeat <= 1 { return .full }                                  // no subdivisions to speak
        if secondsPerTick >= Self.minSpokenSubdivisionSeconds { return .full } // a subdivision syllable fits
        // A sixteenth grid gets the middle rung: speak the eighth positions if an EIGHTH interval fits.
        if ticksPerBeat == 4, 2 * secondsPerTick >= Self.minSpokenSubdivisionSeconds { return .eighthsOnly }
        return .beatsOnly
    }

    /// Whether the in-beat tick position `pos` *speaks* its token at this tempo (given the degrade tier), or
    /// clicks instead. Beats (`pos == 0`) always speak their number. One source of truth for both the render
    /// loop and the next-spoken-onset scan, so the audible schedule and the hard-cut agree exactly.
    @inline(__always)
    func speaksSubdivision(atPosInBeat pos: Int) -> Bool {
        guard pos != 0 else { return true }                       // the beat: always speaks its number
        switch voiceDetail {
        case .full:        return true
        case .eighthsOnly: return ticksPerBeat == 4 && pos == 2   // only the "and" (the eighth) speaks
        case .beatsOnly:   return false
        }
    }

    /// Whether Voice mode speaks *all* the subdivision syllables at this tempo (the `.full` tier). Main beats
    /// always speak their number regardless; this is only the top rung of the degrade ladder.
    @inline(__always)
    var speaksSubdivisionSyllables: Bool { voiceDetail == .full }

    /// The gap-click trainer's decision for tick `n` (a global tick index from playback start): whether to
    /// sound it, silence it, or keep only a soft downbeat. Returns `.play` when the trainer is disabled,
    /// so the default render path is unchanged. Timing is *never* affected — only whether a voice fires.
    @inline(__always)
    func trainerGate(forTick n: Int) -> GapTrainer.Gate {
        guard trainer.isEnabled else { return .play }
        let tpb = max(ticksPerBeat, 1)
        let globalBeat = n / tpb
        let posInBeat = n % tpb
        return trainer.gate(globalBeat: globalBeat, beatsPerBar: beatsPerBar, posInBeat: posInBeat)
    }

    /// Absolute frame index (from playback start) of tick `n` — closed form, zero cumulative drift.
    /// Swing shifts off-beat pair members via the shared `SwingGrid`; at `swing == 0` this is exactly
    /// `round(n × framesPerTick)`, identical to `MetronomeConfiguration.frame(forTick:sampleRate:)`.
    @inline(__always)
    func frame(forTick n: Int) -> Int {
        SwingGrid.frame(forTick: n, ticksPerBeat: ticksPerBeat, framesPerTick: framesPerTick, swing: swing)
    }

    /// Emphasis of tick `n` (global tick index from playback start). A muted beat silences its whole span
    /// (on-beat click and its subdivisions); the engine still publishes the pulse for it.
    @inline(__always)
    func accentLevel(forTick n: Int) -> AccentLevel {
        let beat = (n / ticksPerBeat) % beatsPerBar
        let beatAccent = accents.indices.contains(beat) ? accents[beat] : .normal
        if beatAccent == .muted { return .muted }
        let pos = n % ticksPerBeat
        if cell.silences(posInBeat: pos, ticksPerBeat: ticksPerBeat) { return .muted }  // cell-silenced tick
        guard pos == 0 else { return .weak }
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
