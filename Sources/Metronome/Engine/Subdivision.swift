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

    /// The bare note-value name **assuming the beat is a quarter note** — literally correct only in ×/4
    /// meters. Kept for internal use and the accuracy-test failure labels; for anything shown to the user
    /// prefer `displayName(in:)` (see the extension below), which derives the true note value from the
    /// meter's actual beat unit (a half note in ×/2, an eighth in ×/8, a dotted quarter in compound).
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

extension Subdivision {
    /// The musically-truthful label for this subdivision **in the context of `signature`**.
    ///
    /// `Subdivision` is really *clicks-per-beat* (1, 2, 3, 4, …), so the note value each click represents
    /// depends on what the beat is: the **denominator note** in a simple meter (a half in ×/2, a quarter in
    /// ×/4, an eighth in ×/8), a **dotted quarter** in a compound meter (6/8, 9/8, 12/8). The bare
    /// `displayName` (Quarter/Eighth/…) is only literally true when the beat is a quarter. This derives the
    /// real note value from `beat unit ÷ clicks-per-beat`, so the label always tells the musical truth —
    /// e.g. in 4/2 "one click per beat" is a **Half** note (not a Quarter); in 3/8 it is an **Eighth**.
    func displayName(in signature: TimeSignature) -> String {
        // Compound meters (6/8, 9/8, 12/8): the beat is a dotted quarter and `compoundDisplayName` already
        // tells the truth (Main beat / Eighths / Sixteenths). Keep that behaviour, don't regress it.
        guard !signature.isCompound else { return compoundDisplayName }

        // Simple meter: the beat is the denominator note (2 → half, 4 → quarter, 8 → eighth, 16 → 16th).
        let beatDenominator = signature.denominator
        switch self {
        case .quarter, .eighth, .sixteenth, .thirtysecond:
            // Even (binary) divisions: each click is a 1/(beatDenominator × clicksPerBeat) note.
            return Subdivision.cleanNoteName(beatDenominator * ticksPerBeat)
                ?? Subdivision.beatFractionLabel(ticksPerBeat)
        case .triplet:
            // Three in the space of one beat: each member is drawn as the note that would give two per
            // beat — an eighth-note triplet in ×/4, a quarter-note triplet in ×/2, a 16th triplet in ×/8.
            if let member = Subdivision.cleanNoteName(beatDenominator * 2) { return "\(member) triplet" }
            return "\(Subdivision.beatFractionLabel(3)) (triplet)"
        case .quintuplet, .sextuplet, .septuplet:
            // Higher tuplets are named by their count (N per beat) — already beat-relative and true in any
            // meter; a single note value for a 5/6/7-tuplet would be ambiguous.
            return displayName
        }
    }

    /// A clean, common note-value name for a `1/den`-of-a-whole note, or `nil` past a 32nd (a 64th/128th is
    /// deliberately *not* named here — those very deep subdivisions fall back to a beat-relative label).
    private static func cleanNoteName(_ den: Int) -> String? {
        switch den {
        case 1:  return "Whole"
        case 2:  return "Half"
        case 4:  return "Quarter"
        case 8:  return "Eighth"
        case 16: return "Sixteenth"
        case 32: return "32nd"
        default: return nil
        }
    }

    /// A beat-relative label for a click with no clean note name (very deep subdivisions), e.g. "½ beat".
    private static func beatFractionLabel(_ clicksPerBeat: Int) -> String {
        switch clicksPerBeat {
        case 1:  return "1 beat"
        case 2:  return "½ beat"
        case 3:  return "⅓ beat"
        case 4:  return "¼ beat"
        case 5:  return "⅕ beat"
        case 6:  return "⅙ beat"
        case 7:  return "1/7 beat"
        case 8:  return "⅛ beat"
        default: return "1/\(clicksPerBeat) beat"
        }
    }
}
