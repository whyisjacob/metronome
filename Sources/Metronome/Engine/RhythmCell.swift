import Foundation

/// A preset idiomatic rhythm "cell" laid over the **sixteenth** grid: only certain of the four
/// sub-positions of each beat sound, so a plain sixteenth pulse becomes a recognisable groove figure.
///
/// It reuses the engine's existing per-tick muting — a silenced sub-position returns `.muted` from
/// `accentLevel(forTick:)`, exactly like a muted beat, so no click sounds there but the pulse still
/// advances the count/visual — and it never touches onset *timing*: the four sixteenths stay on their
/// sample-accurate grid; the cell only decides which of them are audible. Position 0 (the beat) always
/// sounds and carries the beat's accent, so the cell's downbeat is naturally emphasised over its inner
/// sixteenths.
///
/// The patterns are the common ones:
///   * `.dottedEighthSixteenth` — `[0, 3]`: a dotted-eighth followed by a sixteenth (the "long–short").
///   * `.gallop` — `[0, 2, 3]`: eighth then two sixteenths (the classic "da-da-dat" gallop).
///   * `.reverseGallop` — `[0, 1, 3]`: two sixteenths then an eighth (the reverse / "dat-da-da").
enum RhythmCell: String, CaseIterable, Identifiable, Codable {
    /// Off — every sixteenth sounds (the plain, un-celled pulse). The default.
    case straight
    case dottedEighthSixteenth
    case gallop
    case reverseGallop

    var id: String { rawValue }

    /// The sixteenth sub-positions (0…3 within a beat) that sound. `.straight` sounds all four.
    var soundingPositions: Set<Int> {
        switch self {
        case .straight:             return [0, 1, 2, 3]
        case .dottedEighthSixteenth: return [0, 3]
        case .gallop:               return [0, 2, 3]
        case .reverseGallop:        return [0, 1, 3]
        }
    }

    /// Whether tick `posInBeat` is silenced by this cell. Cells apply **only** on the sixteenth grid
    /// (`ticksPerBeat == 4`); at any other subdivision — or when the cell is `.straight` — nothing is
    /// silenced, so selecting a cell is a no-op until the sixteenth subdivision is active.
    @inline(__always)
    func silences(posInBeat pos: Int, ticksPerBeat tpb: Int) -> Bool {
        guard self != .straight, tpb == 4 else { return false }
        return !soundingPositions.contains(pos)
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .straight:              return "Off"
        case .dottedEighthSixteenth: return "Dotted 8th + 16th"
        case .gallop:                return "Gallop"
        case .reverseGallop:         return "Reverse gallop"
        }
    }

    /// A compact rhythm sketch of the sounding positions, for the picker caption.
    var caption: String {
        switch self {
        case .straight:              return "All four sixteenths"
        case .dottedEighthSixteenth: return "♩. ♬  (long–short)"
        case .gallop:                return "♪ ♬  (da-da-dat)"
        case .reverseGallop:         return "♬ ♪  (dat-da-da)"
        }
    }
}
