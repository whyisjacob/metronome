import Foundation

/// How each beat (pulse) is divided into audible clicks.
///
/// The tuplets (quintuplet / sextuplet / septuplet) drop straight into the existing tick model — they are
/// just a beat split into 5 / 6 / 7 evenly-spaced clicks — so the sample-accurate, drift-free onset math
/// (`round(n × framesPerTick)`) and the offline-render accuracy proof cover them with no special-casing.
enum Subdivision: String, CaseIterable, Identifiable, Codable, Hashable {
    case quarter
    case eighth
    case triplet
    case sixteenth
    case quintuplet
    case sextuplet
    case septuplet
    case thirtysecond

    var id: String { rawValue }

    /// Number of clicks per beat (simple meters: the beat is the denominator note).
    var ticksPerBeat: Int {
        switch self {
        case .quarter:      return 1
        case .eighth:       return 2
        case .triplet:      return 3
        case .sixteenth:    return 4
        case .quintuplet:   return 5
        case .sextuplet:    return 6
        case .septuplet:    return 7
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
    /// Simple meters are unchanged (`ticksPerBeat`). Tuplets are only offered in simple meters (they are
    /// not in `compoundCases`), so they fall through to their simple tick count.
    func ticksPerBeat(compound: Bool) -> Int {
        guard compound else { return ticksPerBeat }
        switch self {
        case .quarter:      return 1
        case .eighth:       return 3
        case .triplet:      return 3
        case .sixteenth:    return 6
        case .thirtysecond: return 12
        case .quintuplet:   return 5   // not offered in compound; keep the simple meaning if forced
        case .sextuplet:    return 6
        case .septuplet:    return 7
        }
    }

    /// The subdivisions offered in a **compound** meter: the dotted-quarter beat itself, its eighths (the
    /// compound pulse), and its sixteenths. Triplet/tuplets/32nd are hidden there — they don't add a
    /// distinct division of a dotted quarter.
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
        case .quintuplet:   return "Quintuplet"   // not shown in the compound picker
        case .sextuplet:    return "Sextuplet"
        case .septuplet:    return "Septuplet"
        }
    }

    var displayName: String {
        switch self {
        case .quarter:      return "Quarter"
        case .eighth:       return "Eighth"
        case .triplet:      return "Triplet"
        case .sixteenth:    return "Sixteenth"
        case .quintuplet:   return "Quintuplet"
        case .sextuplet:    return "Sextuplet"
        case .septuplet:    return "Septuplet"
        case .thirtysecond: return "32nd"
        }
    }

    /// A short label for a compact control.
    var symbol: String {
        switch self {
        case .quarter:      return "♩"
        case .eighth:       return "♫"
        case .triplet:      return "³"
        case .sixteenth:    return "♬"
        case .quintuplet:   return "⁵"
        case .sextuplet:    return "⁶"
        case .septuplet:    return "⁷"
        case .thirtysecond: return "³²"
        }
    }
}
