import SwiftUI

/// The app's own minimal, dark, high-contrast identity — nothing borrowed from other projects.
enum Theme {
    static let background     = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let surface        = Color(red: 0.10, green: 0.11, blue: 0.14)
    static let surfaceRaised  = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let stroke         = Color(white: 1.0, opacity: 0.08)

    static let textPrimary    = Color(white: 0.97)
    static let textSecondary  = Color(white: 0.62)

    /// Downbeat / accented beat.
    static let accentStrong   = Color(red: 1.00, green: 0.42, blue: 0.16)
    /// Unaccented beat.
    static let accentNormal   = Color(red: 1.00, green: 0.76, blue: 0.22)
    /// Idle (not currently sounding) beat dot.
    static let beatIdle       = Color(white: 0.24)

    static let start          = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let stop           = Color(red: 0.95, green: 0.30, blue: 0.32)

    /// Colour for a beat dot given whether it is the currently sounding beat.
    static func beatColor(isActive: Bool, accented: Bool) -> Color {
        guard isActive else { return beatIdle }
        return accented ? accentStrong : accentNormal
    }
}
