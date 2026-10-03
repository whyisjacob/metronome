import SwiftUI

/// The app's own minimal, dark, high-contrast identity — nothing borrowed from other projects.
enum Theme {
    static let background     = Color(white: 0.065)
    static let surface        = Color(white: 0.105)
    static let surfaceRaised  = Color(white: 0.16)
    static let stroke         = Color(white: 1.0, opacity: 0.08)

    static let textPrimary    = Color(white: 0.97)
    static let textSecondary  = Color(white: 0.62)

    /// Downbeat / primary accent.
    static let accentStrong   = Color(red: 0.90, green: 0.77, blue: 0.51)
    /// Secondary (medium) accent — between strong and normal.
    static let accentMedium   = Color(red: 0.77, green: 0.69, blue: 0.52)
    /// Unaccented beat.
    static let accentNormal   = Color(red: 0.82, green: 0.75, blue: 0.59)
    /// Idle (not currently sounding) beat dot.
    static let beatIdle       = Color(white: 0.24)
    /// A muted beat marker (present, but silent).
    static let beatMuted      = Color(white: 0.32)

    static let start          = Color(white: 0.90)
    static let stop           = Color(red: 0.85, green: 0.49, blue: 0.44)

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
