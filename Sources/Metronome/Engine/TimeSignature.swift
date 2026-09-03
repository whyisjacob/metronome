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
    static let numeratorRange = 1...16

    init(numerator: Int, denominator: Int) {
        self.numerator = numerator.clamped(to: TimeSignature.numeratorRange)
        self.denominator = TimeSignature.allowedDenominators.contains(denominator) ? denominator : 4
    }

    static let common = TimeSignature(numerator: 4, denominator: 4)

    var displayString: String { "\(numerator)/\(denominator)" }
}
