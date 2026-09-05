import SwiftUI

/// The app's own minimal, dark, high-contrast identity — nothing borrowed from other projects.
enum Theme {
    static let background     = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let surface        = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let surfaceRaised  = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let stroke         = Color(white: 1.0, opacity: 0.08)

    static let textPrimary    = Color(white: 0.97)
    static let textSecondary  = Color(white: 0.62)

    /// Downbeat / primary accent.
    static let accentStrong   = Color(red: 1.00, green: 0.42, blue: 0.16)
    /// Secondary (medium) accent — between strong and normal.
    static let accentMedium   = Color(red: 1.00, green: 0.58, blue: 0.19)
    /// Unaccented beat.
    static let accentNormal   = Color(red: 1.00, green: 0.76, blue: 0.22)
    /// Pickup / count-in lead-in beat — a cool colour, deliberately distinct from the warm accent hues so
    /// a count-in reads as a lead-in, not a downbeat.
    static let accentPickup   = Color(red: 0.35, green: 0.78, blue: 0.92)
    /// Idle (not currently sounding) beat dot.
    static let beatIdle       = Color(white: 0.24)
    /// A muted beat marker (present, but silent).
    static let beatMuted      = Color(white: 0.32)

    static let start          = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let stop           = Color(red: 0.95, green: 0.30, blue: 0.32)

    /// Colour for a beat dot given whether it is the currently sounding beat.
    static func beatColor(isActive: Bool, accented: Bool) -> Color {
        guard isActive else { return beatIdle }
        return accented ? accentStrong : accentNormal
    }

    /// Colour for a beat dot given its accent state and whether it is the currently sounding beat. Muted
    /// beats read as a dim marker even when active (they advance but never sound).
    static func beatColor(for accent: BeatAccent, isActive: Bool) -> Color {
        guard isActive else { return accent == .muted ? beatMuted.opacity(0.6) : beatIdle }
        switch accent {
        case .strong: return accentStrong
        case .medium: return accentMedium
        case .normal: return accentNormal
        case .muted:  return beatMuted
        }
    }
}
