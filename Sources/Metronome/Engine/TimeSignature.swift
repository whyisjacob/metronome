import Foundation

/// A musical time signature: `numerator` beats per bar, each a `denominator`-note.
///
/// Timing model: the metronome pulses `beatsPerBar` times per bar at the set BPM, where a *beat* is the
/// denominator note for simple meters and a *dotted quarter* for compound meters (6/8, 9/8, 12/8). So
/// 120 BPM is 120 quarter-notes/min in 4/4 and 120 **dotted-quarters**/min in 6/8 (the jig "in 2" feel,
/// reachable at real jig tempos), with the eighth pulse available as a 3-per-beat subdivision.
struct TimeSignature: Equatable, Hashable, Codable {
    /// Beats per bar. Always within `numeratorRange`.
    let numerator: Int
    /// The note value that gets one beat. Always one of `allowedDenominators`.
    let denominator: Int

    static let allowedDenominators = [2, 4, 8, 16]
    /// Beats per bar. Widened to 32 so odd/large meters (5, 7, 11, 13, …) can be dialed in; the
    /// engine, accent pattern, and `SongPlan` all handle an arbitrary numerator (they index by
    /// `beat % numerator`), so nothing here is preset-bound.
    static let numeratorRange = 1...32

    init(numerator: Int, denominator: Int) {
        self.numerator = numerator.clamped(to: TimeSignature.numeratorRange)
        self.denominator = TimeSignature.allowedDenominators.contains(denominator) ? denominator : 4
    }

    static let common = TimeSignature(numerator: 4, denominator: 4)

    var displayString: String { "\(numerator)/\(denominator)" }

    // MARK: - Compound meter

    /// A compound meter groups its eighth-note pulses in threes: an `x/8` meter whose numerator is a
    /// multiple of three and ≥ 6 (6/8, 9/8, 12/8, …). 3/8 stays *simple* (a single group), and any
    /// non-`/8` meter is simple regardless of numerator (6/4 is duple-simple, not compound).
    var isCompound: Bool { denominator == 8 && numerator >= 6 && numerator % 3 == 0 }

    /// Number of dotted-quarter groups in a compound bar (2 for 6/8, 3 for 9/8, 4 for 12/8); `nil` for
    /// simple meters. Equals `beatsPerBar` for a compound meter.
    var compoundGroupCount: Int? { isCompound ? numerator / 3 : nil }

    /// The number of **main beats (pulses) per bar** — the length of the accent pattern and what the
    /// engine actually pulses. Compound meters are felt in dotted-quarter groups, so `6/8` is 2 beats,
    /// `9/8` is 3, `12/8` is 4; every simple meter is `numerator` beats.
    var beatsPerBar: Int { isCompound ? numerator / 3 : numerator }

    /// The default *grouping* of a simple meter's beats — the group sizes (summing to `beatsPerBar`) whose
    /// heads take a secondary (medium) accent. Asymmetric meters get their conventional grouping (5/8 →
    /// 2+3, 7/8 → 2+2+3, 5/4 → 3+2), 4/4 gets its familiar 2+2 (a medium on beat 3), and everything else
    /// is a single group (downbeat only). Compound meters don't use this — each dotted-quarter beat is its
    /// own group head (see `defaultAccents`).
    var defaultGrouping: [Int] {
        switch (numerator, denominator) {
        case (4, _):  return [2, 2]        // 4/4 → beat 1 strong, beat 3 medium
        case (5, 8):  return [2, 3]        // 5/8 → accents on 1, 3
        case (5, _):  return [3, 2]        // 5/4 → accents on 1, 4
        case (7, 8):  return [2, 2, 3]     // 7/8 → accents on 1, 3, 5
        default:      return [max(beatsPerBar, 1)]   // single group: downbeat only
        }
    }

    /// The sensible default accent pattern for this meter, one `BeatAccent` per **main beat**:
    ///   * Compound (6/8, 9/8, 12/8): every dotted-quarter beat is a group head — beat 1 `strong`, the
    ///     rest `medium` (so 12/8 is 1-strong, 4/7/10-medium in eighth terms).
    ///   * Simple: the downbeat is `strong`, each subsequent group head (per `defaultGrouping`) is
    ///     `medium`, and every other beat is `normal`.
    /// Always `beatsPerBar` long with beat 1 accented, so it drops straight into `MetronomeConfiguration`.
    var defaultAccents: [BeatAccent] {
        let count = max(beatsPerBar, 0)
        var pattern = [BeatAccent](repeating: .normal, count: count)
        guard !pattern.isEmpty else { return pattern }
        pattern[0] = .strong
        if isCompound {
            for i in 1..<count { pattern[i] = .medium }
        } else {
            var index = 0
            for size in defaultGrouping {
                if index > 0 && index < count { pattern[index] = .medium }   // subsequent group heads
                index += size
            }
        }
        return pattern
    }
}
