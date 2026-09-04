import Foundation

/// How each beat (pulse) is divided into audible clicks.
enum Subdivision: String, CaseIterable, Identifiable, Codable, Hashable {
    case quarter
    case eighth
    case triplet
    case sixteenth
    case thirtysecond

    var id: String { rawValue }

    /// Number of clicks per beat (simple meters: the beat is the denominator note).
    var ticksPerBeat: Int {
        switch self {
        case .quarter: return 1
        case .eighth: return 2
        case .triplet: return 3
        case .sixteenth: return 4
        case .thirtysecond: return 8
        }
    }

    /// Clicks per beat given whether the enclosing meter is **compound** (6/8, 9/8, 12/8). In a compound
    /// meter the beat is a *dotted quarter* that natively divides into three eighths, so the subdivision
    /// is interpreted relative to that beat rather than to the denominator eighth:
    ///   * `.quarter`  → 1 — the dotted-quarter main beat only ("felt in 2/3/4"), the compound default.
    ///   * `.eighth`   → 3 — the compound eighths, i.e. the defining pulse of the meter.
    ///   * `.triplet`  → 3 — same three-per-beat division (offered as an alias).
    ///   * `.sixteenth`→ 6 — compound sixteenths.
    ///   * `.thirtysecond` → 12.
    /// Simple meters are unchanged (`ticksPerBeat`).
    func ticksPerBeat(compound: Bool) -> Int {
        guard compound else { return ticksPerBeat }
        switch self {
        case .quarter:      return 1
        case .eighth:       return 3
        case .triplet:      return 3
        case .sixteenth:    return 6
        case .thirtysecond: return 12
        }
    }

    /// The subdivisions offered in a **compound** meter: the dotted-quarter beat itself, its eighths (the
    /// compound pulse), and its sixteenths. Triplet/32nd are hidden there — they don't add a distinct
    /// division of a dotted quarter.
    static let compoundCases: [Subdivision] = [.quarter, .eighth, .sixteenth]

    /// Display name of the subdivision as heard in a compound meter (where `.quarter` is the main beat and
    /// `.eighth` is the three-per-beat pulse).
    var compoundDisplayName: String {
        switch self {
        case .quarter:      return "Main beat"
        case .eighth:       return "Eighths"
        case .sixteenth:    return "Sixteenths"
        case .triplet:      return "Eighths"
        case .thirtysecond: return "32nds"
        }
    }

    var displayName: String {
        switch self {
        case .quarter: return "Quarter"
        case .eighth: return "Eighth"
        case .triplet: return "Triplet"
        case .sixteenth: return "Sixteenth"
        case .thirtysecond: return "32nd"
        }
    }

    /// A short label for a compact control.
    var symbol: String {
        switch self {
        case .quarter: return "♩"
        case .eighth: return "♫"
        case .triplet: return "³"
        case .sixteenth: return "♬"
        case .thirtysecond: return "³²"
        }
    }
}
