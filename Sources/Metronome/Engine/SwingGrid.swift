import Foundation

/// Swing / shuffle onset math, shared **verbatim** by `MetronomeConfiguration.frame(forTick:sampleRate:)`
/// and `RenderPlan.frame(forTick:)` so the value proven correct by the pure-math unit tests is the exact
/// value the audio render path uses (floating-point multiplication is not associative — the two callers
/// must group the operands identically, which sharing this one function guarantees).
///
/// ## Model
/// Swing delays the **off-beat** member of each subdivision *pair* toward the triplet position, leaving the
/// on-beat members exactly where they were:
///   * Eighths (`ticksPerBeat == 2`): one pair per beat `[0, 1]`; the off-eighth (tick 1) moves from ½ of
///     the beat (straight) to ⅔ (full swing) — i.e. the classic shuffle where the beat splits 2:1.
///   * Sixteenths (`ticksPerBeat == 4`): two pairs per beat `[0, 1]` and `[2, 3]`; the "e" and "a" move to
///     ⅔ of their eighth, while the beat and the "and" (the on-eighth pulses) stay put.
/// The off member's fraction of the beat is `pairStart + (0.5 + swing/6) · pairLength`, which is exactly
/// ½→⅔ of the pair as `swing` runs 0→1. Only even `ticksPerBeat` in `{2, 4}` swing; triplets, tuplets,
/// compound divisions and 32nds are left straight.
///
/// ## Drift
/// The returned frame is a **closed form** — `round((beat + fraction) × framesPerBeat)` — never an
/// accumulation of per-tick durations, so the deviation from the ideal continuous time is bounded by ±½
/// sample for *every* tick and never compounds. When `swing == 0` (the default) — or the division does not
/// swing, or the tick is an on-beat member — this returns the original `round(n × framesPerTick)` path
/// byte-for-byte, so nothing about the non-swung metronome changes.
enum SwingGrid {

    /// Whether a subdivision with `ticksPerBeat` ticks swings: eighths (2) and sixteenths (4) pair up;
    /// everything else (quarter, triplet, tuplets, compound divisions, 32nds) stays straight.
    @inline(__always)
    static func swings(ticksPerBeat tpb: Int) -> Bool { tpb == 2 || tpb == 4 }

    /// Absolute onset frame (from playback start) of tick `n`, with swing applied to off-beat pair members.
    /// `framesPerTick` is the *straight* inter-click interval (`secondsPerTick × sampleRate`); `swing` is
    /// clamped-elsewhere to `[0, 1]`.
    @inline(__always)
    static func frame(forTick n: Int, ticksPerBeat tpb: Int, framesPerTick: Double, swing: Double) -> Int {
        // Fast path: no swing (or a non-swinging division) → the original closed form, unchanged.
        guard swing > 0, swings(ticksPerBeat: tpb) else {
            return Int((Double(n) * framesPerTick).rounded())
        }
        let pos = n % tpb
        // On-beat pair members (even position within the beat) never move — the main beats and, for
        // sixteenths, the "and" pulse stay exactly on the straight grid.
        guard pos % 2 == 1 else {
            return Int((Double(n) * framesPerTick).rounded())
        }
        // Off-beat member: place it as a fraction of the beat, from a whole-beat base — closed form.
        let framesPerBeat = framesPerTick * Double(tpb)
        let beat = n / tpb
        let pairStart = Double(pos - 1) / Double(tpb)          // fraction of the beat where the pair begins
        let pairLength = 2.0 / Double(tpb)                     // fraction of the beat one pair spans
        let offFraction = pairStart + (0.5 + swing / 6.0) * pairLength
        return Int(((Double(beat) + offFraction) * framesPerBeat).rounded())
    }
}
