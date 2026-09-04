import Foundation

/// A musical time signature: `numerator` beats per bar, each a `denominator`-note.
///
/// v1 timing model: the metronome pulses `numerator` times per bar at the set BPM. The
/// `denominator` is recorded (and displayed) but does not by itself change the pulse rate —
/// 120 BPM is 120 pulses/min in 4/4 and in 6/8 alike. This matches common metronome apps and keeps
/// the timing grid unambiguous. Proper compound-meter grouping is a Song Builder concern (ROADMAP).
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
    /// simple meters. Used to reflect the grouping in counting without changing the pulse count.
    var compoundGroupCount: Int? { isCompound ? numerator / 3 : nil }

    /// The sensible default accent pattern for this meter: the downbeat alone for simple meters, and
    /// every group head (beats 1, 4, 7, 10, …) for compound meters. Always `numerator` long with at
    /// least beat 1 accented, so it drops straight into `MetronomeConfiguration`.
    var defaultAccents: [Bool] {
        var pattern = [Bool](repeating: false, count: max(numerator, 0))
        guard !pattern.isEmpty else { return pattern }
        if isCompound {
            for i in stride(from: 0, to: numerator, by: 3) { pattern[i] = true }
        } else {
            pattern[0] = true
        }
        return pattern
    }
}
