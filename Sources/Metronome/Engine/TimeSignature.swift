import Foundation

/// A notated meter plus the note value counted by the tempo. Compound beats contain
/// three denominator notes; counting individual denominator notes remains an explicit choice.
struct TimeSignature: Equatable, Hashable, Codable {
    let numerator: Int
    let denominator: Int
    let groupedBeats: Bool

    static let allowedDenominators = [2, 4, 8, 16]
    /// Beats per bar. Widened to 32 so odd/large meters (5, 7, 11, 13, …) can be dialed in; the
    /// engine, accent pattern, and `SongPlan` all handle an arbitrary numerator (they index by
    /// `beat % numerator`), so nothing here is preset-bound.
    static let numeratorRange = 1...32

    init(numerator: Int, denominator: Int, groupedBeats: Bool? = nil) {
        self.numerator = numerator.clamped(to: TimeSignature.numeratorRange)
        self.denominator = TimeSignature.allowedDenominators.contains(denominator) ? denominator : 4
        let canGroup = self.numerator >= 3 && self.numerator % 3 == 0
        // Only eighth/sixteenth meters (6/8, 9/8, 12/8, 9/16 …) default to dotted-beat grouping. Quarter and
        // half meters (6/4, 9/4, 6/2, 12/4 …) count the denominator note — 6/4 is "1 2 3 4 5 6" — unless the
        // user explicitly picks the dotted beat via the "Tempo beat" control.
        self.groupedBeats = canGroup && (groupedBeats ?? (self.numerator >= 6 && self.denominator >= 8))
    }

    static let common = TimeSignature(numerator: 4, denominator: 4)

    var displayString: String { "\(numerator)/\(denominator)" }

    // MARK: - Compound meter

    /// Any multiple-of-three numerator *can* be grouped into dotted beats (6/4, 9/16, 12/2 …), but only
    /// x/8 and x/16 do so by default. 3/x defaults to three beats but can explicitly be counted as one.
    var canGroupBeats: Bool { numerator >= 3 && numerator % 3 == 0 }
    var isCompound: Bool { groupedBeats }
    var compoundGroupCount: Int? { isCompound ? numerator / 3 : nil }
    var beatsPerBar: Int { isCompound ? numerator / 3 : numerator }

    var denominatorNoteName: String {
        switch denominator {
        case 2: return "Half note"
        case 8: return "Eighth note"
        case 16: return "Sixteenth note"
        default: return "Quarter note"
        }
    }

    var groupedNoteName: String {
        switch denominator {
        case 2: return "Dotted whole"
        case 4: return "Dotted half"
        case 16: return "Dotted eighth"
        default: return "Dotted quarter"
        }
    }

    var beatUnitName: String { isCompound ? groupedNoteName : denominatorNoteName }

    /// Length of one counted beat as a fraction of a whole note: the denominator note in a simple meter
    /// (4/2 → ½, 4/4 → ¼), the dotted note in a grouped/compound one (6/8 → ⅜, 6/4 grouped → ¾).
    /// The BPM always counts *this* note, so converting tempo between meters is `bpm × oldValue / newValue`.
    var beatValue: Double { Double(isCompound ? 3 : 1) / Double(denominator) }

    enum CodingKeys: String, CodingKey { case numerator, denominator, groupedBeats }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try c.decode(Int.self, forKey: .numerator)
        let d = try c.decode(Int.self, forKey: .denominator)
        // Existing songs/recents must retain their original audible tempo and bar length.
        let grouped = try c.decodeIfPresent(Bool.self, forKey: .groupedBeats)
            ?? (d == 8 && n >= 6 && n % 3 == 0)
        self.init(numerator: n, denominator: d, groupedBeats: grouped)
    }

    /// The default *grouping* of a simple meter's beats — the group sizes (summing to `beatsPerBar`) whose
    /// heads take a secondary (medium) accent. Asymmetric meters get their conventional grouping (5/8 →
    /// 2+3, 7/8 → 2+2+3, 5/4 → 3+2), 4/4 gets its familiar 2+2 (a medium on beat 3), and everything else
    /// is a single group (downbeat only). Compound meters don't use this — each dotted-quarter beat is its
    /// own group head (see `defaultAccents`).
    var defaultGrouping: [Int] {
        if isCompound { return [beatsPerBar] }
        switch (numerator, denominator) {
        case (4, _):  return [2, 2]        // 4/4 → beat 1 strong, beat 3 medium
        case (5, 8):  return [2, 3]        // 5/8 → accents on 1, 3
        case (5, _):  return [3, 2]        // 5/4 → accents on 1, 4
        case (7, 8):  return [2, 2, 3]     // 7/8 → accents on 1, 3, 5
        // Triple-grouped numerators counted in their denominator note (6/4, 6/8 counted in six, 9/4, 12/4, 6/2 …):
        // the beats still fall in threes, so each group head after the first takes a secondary accent.
        case (6, _):  return [3, 3]
        case (9, _):  return [3, 3, 3]
        case (12, _): return [3, 3, 3, 3]
        default:      return [max(beatsPerBar, 1)]   // single group: downbeat only
        }
    }

    /// The sensible default accent pattern for this meter, one `BeatAccent` per **main beat**:
    ///   * Compound duple/triple (6/8, 9/8): every dotted-quarter beat is a group head — beat 1 `strong`,
    ///     the rest `medium` (6/8 → `[strong, medium]`, 9/8 → `[strong, medium, medium]`).
    ///   * Compound quadruple (12/8): a compound 4/4 — beat 1 `strong`, the THIRD dotted-quarter beat the
    ///     mid-bar secondary (`medium`), beats 2 & 4 `normal` → `[strong, normal, medium, normal]`.
    ///   * Simple: the downbeat is `strong`, each subsequent group head (per `defaultGrouping`) is
    ///     `medium`, and every other beat is `normal`.
    /// Always `beatsPerBar` long with beat 1 accented, so it drops straight into `MetronomeConfiguration`.
    var defaultAccents: [BeatAccent] {
        let count = max(beatsPerBar, 0)
        var pattern = [BeatAccent](repeating: .normal, count: count)
        guard !pattern.isEmpty else { return pattern }
        pattern[0] = .strong
        if isCompound {
            if count == 4 {
                // 12/8 is a compound 4/4: the mid-bar secondary accent is the THIRD dotted-quarter beat;
                // beats 2 & 4 stay `normal`. (6/8 → [strong, medium] and 9/8 → [strong, medium, medium]
                // keep the every-group-head rule in the else branch.)
                pattern[2] = .medium
            } else {
                for i in 1..<count { pattern[i] = .medium }
            }
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
