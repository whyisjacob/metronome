import Foundation

/// The **gap-click trainer** — an internal-time practice tool that silences beats so the musician has to
/// hold the pulse through the gaps. It is deliberately a **pure value type** with no audio or engine
/// dependency: given a beat's position it returns a `Gate` telling the engine whether to sound the beat,
/// silence it, or keep only a soft reference downbeat. That purity is what makes the whole muting policy
/// unit-testable with no synthesizer and no `AVAudioEngine`.
///
/// ## How it rides the sample-accurate schedule
/// The trainer **never** changes *when* a click is due — it only decides *whether* a beat sounds. The
/// engine keeps placing onsets at `round(tick × framesPerTick)` exactly as before and still publishes a
/// pulse for every tick (so the count and the on-screen beat keep advancing); a silenced beat simply
/// emits no click. This is the identical mechanism the per-beat `.muted` accent already uses, so the
/// timing engine stays drift-free and the accuracy tests are unaffected (a disabled trainer — the
/// default — returns `.play` for every beat, i.e. byte-for-byte the original behaviour).
///
/// ## Modes
///  - **Random** — mute a set percentage of beats at random, using a *seedable* hash so the pattern is
///    reproducible in tests (fixed seed) yet unpredictable in the app (a fresh random seed each run).
///  - **Bars on/off** — play `barsOn` bars, then silence `barsOff` bars, repeating.
///  - **Ramp** (optional, layered on either mode) — make it progressively harder over time: raise the
///    random mute-percent, or lengthen each successive off-phase, as the bars go by.
struct GapTrainer: Equatable, Codable {

    /// Which silencing policy is active.
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case random
        case barsOnOff
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .random:    return "Random"
            case .barsOnOff: return "Bars on/off"
            }
        }
    }

    /// The engine's per-beat decision. `softDownbeat` is only ever returned for the bar's downbeat tick
    /// when `keepDownbeat` is on: the bar is a gap, but a quiet reference click keeps you from losing the
    /// downbeat.
    enum Gate: Equatable {
        case play
        case silence
        case softDownbeat
    }

    // MARK: Stored settings

    var isEnabled: Bool = false
    var mode: Mode = .random

    /// Random mode: the base percentage of beats to mute (0…100).
    var mutePercent: Int = 25

    /// Bars mode: play this many bars…
    var barsOn: Int = 2
    /// …then silence this many.
    var barsOff: Int = 2

    /// Keep a soft, quiet downbeat audible on otherwise-silenced bars so the bar is never lost.
    var keepDownbeat: Bool = true

    /// Seed for the random pattern. Fixed by default (deterministic); the app randomises it per run so the
    /// gaps are unpredictable, while tests pin it for reproducibility.
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D

    // MARK: Ramp (optional, on top of either mode)

    var rampEnabled: Bool = false
    /// Random mode: number of bars over which the mute-percent climbs from `mutePercent` to
    /// `rampMutePercentPeak`, after which it holds at the peak.
    var rampBars: Int = 8
    /// Random mode: the mute-percent at the top of the ramp (0…100).
    var rampMutePercentPeak: Int = 80
    /// Bars mode: the off-phase grows by one bar each cycle up to this many off-bars.
    var rampBarsOffPeak: Int = 4

    // MARK: - Decision (pure)

    /// The gate for a beat, computed from its position. `globalBeat` is the beat index from playback
    /// start; `beatsPerBar` the meter's pulses per bar; `posInBeat` the tick's offset inside the beat
    /// (0 on the beat itself, >0 on its subdivisions) so that only the true downbeat tick can be the soft
    /// reference click — a silenced beat's subdivisions stay silent.
    func gate(globalBeat: Int, beatsPerBar: Int, posInBeat: Int = 0) -> Gate {
        guard isEnabled else { return .play }
        let bpb = max(beatsPerBar, 1)
        let beatInBar = ((globalBeat % bpb) + bpb) % bpb
        let barIndex = globalBeat >= 0 ? globalBeat / bpb : 0

        let silenced: Bool
        switch mode {
        case .random:    silenced = randomSilenced(globalBeat: globalBeat, barIndex: barIndex)
        case .barsOnOff: silenced = barsModeSilenced(barIndex: barIndex)
        }
        guard silenced else { return .play }

        if keepDownbeat && beatInBar == 0 {
            return posInBeat == 0 ? .softDownbeat : .silence
        }
        return .silence
    }

    // MARK: Random mode

    /// Whether this beat is silenced in random mode. A pure function of `(seed, globalBeat)` — independent
    /// of evaluation order — so the audio thread and the tests agree exactly.
    func randomSilenced(globalBeat: Int, barIndex: Int) -> Bool {
        let fraction = effectiveMuteFraction(barIndex: barIndex)
        if fraction <= 0 { return false }
        if fraction >= 1 { return true }
        return randomRoll(globalBeat: globalBeat) < fraction
    }

    /// The effective mute fraction (0…1) for `barIndex`: the base `mutePercent`, or — when ramping — a
    /// linear climb from `mutePercent` to `rampMutePercentPeak` across `rampBars` bars, then held.
    func effectiveMuteFraction(barIndex: Int) -> Double {
        let base = Double(clamp(mutePercent, 0, 100)) / 100.0
        guard rampEnabled else { return base }
        let peak = Double(clamp(rampMutePercentPeak, 0, 100)) / 100.0
        return base + (peak - base) * rampProgress(barIndex: barIndex)
    }

    /// Ramp progress in 0…1 as a function of the bar index (0 before/at the start, 1 once `rampBars` have
    /// elapsed).
    func rampProgress(barIndex: Int) -> Double {
        guard rampEnabled else { return 0 }
        let denom = Double(max(rampBars, 1))
        return min(1.0, max(0.0, Double(max(barIndex, 0)) / denom))
    }

    /// A uniform value in [0, 1) derived from the seed and beat index via SplitMix64 — a good,
    /// dependency-free hash with no modulo bias (uses the top 53 bits as a Double).
    func randomRoll(globalBeat: Int) -> Double {
        var z = seed &+ (UInt64(bitPattern: Int64(globalBeat)) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2^-53
    }

    // MARK: Bars on/off mode

    /// Whether `barIndex` falls in an off-phase. Without ramp the pattern is periodic (`barsOn` on then
    /// `barsOff` off). With ramp each successive off-phase is one bar longer than the last, up to
    /// `rampBarsOffPeak`; once the cap is reached the pattern is periodic again, so this stays O(cap) —
    /// a small, bounded number of iterations even deep into a long practice session.
    func barsModeSilenced(barIndex: Int) -> Bool {
        let bi = max(0, barIndex)
        let on = max(0, barsOn)
        let baseOff = max(0, barsOff)

        if !rampEnabled {
            let len = on + baseOff
            guard len > 0 else { return false }
            return (bi % len) >= on
        }

        let cap = max(baseOff, max(0, rampBarsOffPeak))
        var bar = 0
        var cycle = 0
        while true {
            let off = min(cap, baseOff + cycle)
            let len = on + off
            guard len > 0 else { return false }
            if off >= cap {
                // Steady state from here on: a fixed-length cycle, so finish with modulo (no unbounded loop).
                let pos = (bi - bar) % len
                return pos >= on
            }
            if bi < bar + on { return false }   // in this cycle's on-phase
            if bi < bar + len { return true }   // in this cycle's off-phase
            bar += len
            cycle += 1
        }
    }

    // MARK: - Normalisation (used by the UI layer to keep settings sane)

    /// Returns a copy with every field clamped to a musically sensible range.
    func normalized() -> GapTrainer {
        var t = self
        t.mutePercent = clamp(mutePercent, 0, 100)
        t.barsOn = clamp(barsOn, 1, 16)
        t.barsOff = clamp(barsOff, 1, 16)
        t.rampBars = clamp(rampBars, 1, 64)
        t.rampMutePercentPeak = clamp(rampMutePercentPeak, 0, 100)
        t.rampBarsOffPeak = clamp(rampBarsOffPeak, 1, 16)
        return t
    }
}

/// Small integer clamp — file-local so it doesn't collide with the engine's `Comparable.clamped(to:)`.
private func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
    min(max(value, lower), upper)
}
