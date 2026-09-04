import Foundation

/// How each beat (pulse) is divided into audible clicks.
enum Subdivision: String, CaseIterable, Identifiable, Codable, Hashable {
    case quarter
    case eighth
    case triplet
    case sixteenth

    var id: String { rawValue }

    /// Number of clicks per beat.
    var ticksPerBeat: Int {
        switch self {
        case .quarter: return 1
        case .eighth: return 2
        case .triplet: return 3
        case .sixteenth: return 4
        }
    }

    var displayName: String {
        switch self {
        case .quarter: return "Quarter"
        case .eighth: return "Eighth"
        case .triplet: return "Triplet"
        case .sixteenth: return "Sixteenth"
        }
    }

    /// A short label for a compact control.
    var symbol: String {
        switch self {
        case .quarter: return "♩"
        case .eighth: return "♫"
        case .triplet: return "³"
        case .sixteenth: return "♬"
        }
    }
}
