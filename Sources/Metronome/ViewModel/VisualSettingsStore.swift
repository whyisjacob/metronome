import SwiftUI

/// Which on-screen beat indicator is shown. Persisted by `VisualSettingsStore`; each case maps to one
/// indicator view in `BeatVisualView`. Every style is driven by the same engine pulse, so the choice is
/// purely cosmetic — it never affects timing or which click sounds.
enum BeatIndicatorStyle: String, CaseIterable, Identifiable, Codable {
    case ball
    case dots
    case counter
    case ring

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ball:    return "Ball"
        case .dots:    return "Dots"
        case .counter: return "Counter"
        case .ring:    return "Ring"
        }
    }

    /// One-line description for the settings picker.
    var caption: String {
        switch self {
        case .ball:    return "Pulsing disc + beat number"
        case .dots:    return "A dot per beat, accent emphasized"
        case .counter: return "Big current-beat number"
        case .ring:    return "Circular ring with subdivisions"
        }
    }

    var symbolName: String {
        switch self {
        case .ball:    return "circle.fill"
        case .dots:    return "ellipsis"
        case .counter: return "textformat.123"
        case .ring:    return "circle.dotted"
        }
    }
}

/// A small curated palette for the screen-border flash, so the accent-beat and normal-beat colours are
/// user-selectable from a fixed, testable set (rather than a free-form colour well). Codable by raw name.
enum FlashColor: String, CaseIterable, Identifiable, Codable {
    case red
    case orange
    case amber
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink
    case white

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red:    return Color(red: 1.00, green: 0.23, blue: 0.19)
        case .orange: return Color(red: 1.00, green: 0.42, blue: 0.16)
        case .amber:  return Color(red: 1.00, green: 0.76, blue: 0.22)
        case .yellow: return Color(red: 1.00, green: 0.92, blue: 0.30)
        case .green:  return Color(red: 0.20, green: 0.80, blue: 0.45)
        case .teal:   return Color(red: 0.20, green: 0.78, blue: 0.80)
        case .blue:   return Color(red: 0.20, green: 0.55, blue: 1.00)
        case .purple: return Color(red: 0.64, green: 0.35, blue: 1.00)
        case .pink:   return Color(red: 1.00, green: 0.30, blue: 0.62)
        case .white:  return Color(white: 0.98)
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// Persists the user's visual preferences — the chosen beat indicator and the screen-border flash
/// (toggle + its two colours) — in `UserDefaults`. Modelled on the app's other small stores
/// (`RecentsStore` / `SongStore`): an injectable backing store so tests use an isolated suite, and plain
/// synchronous reads/writes. No timing state lives here; it only decides how the beat is *shown*.
final class VisualSettingsStore: ObservableObject {

    @Published private(set) var indicatorStyle: BeatIndicatorStyle
    @Published private(set) var borderFlashEnabled: Bool
    @Published private(set) var accentFlashColor: FlashColor
    @Published private(set) var normalFlashColor: FlashColor

    private let defaults: UserDefaults

    private enum Keys {
        static let style = "visual.indicatorStyle"
        static let flashOn = "visual.borderFlashEnabled"
        static let accentColor = "visual.accentFlashColor"
        static let normalColor = "visual.normalFlashColor"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.indicatorStyle = defaults.string(forKey: Keys.style)
            .flatMap(BeatIndicatorStyle.init(rawValue:)) ?? .ball
        // Border flash is opt-in: an absent key reads as `false`.
        self.borderFlashEnabled = defaults.bool(forKey: Keys.flashOn)
        self.accentFlashColor = defaults.string(forKey: Keys.accentColor)
            .flatMap(FlashColor.init(rawValue:)) ?? .orange
        self.normalFlashColor = defaults.string(forKey: Keys.normalColor)
            .flatMap(FlashColor.init(rawValue:)) ?? .blue
    }

    func setIndicatorStyle(_ style: BeatIndicatorStyle) {
        indicatorStyle = style
        defaults.set(style.rawValue, forKey: Keys.style)
    }

    func setBorderFlashEnabled(_ enabled: Bool) {
        borderFlashEnabled = enabled
        defaults.set(enabled, forKey: Keys.flashOn)
    }

    func setAccentFlashColor(_ color: FlashColor) {
        accentFlashColor = color
        defaults.set(color.rawValue, forKey: Keys.accentColor)
    }

    func setNormalFlashColor(_ color: FlashColor) {
        normalFlashColor = color
        defaults.set(color.rawValue, forKey: Keys.normalColor)
    }

    /// The flash colour for a click of the given emphasis: the accent colour on an accented (downbeat)
    /// click, the normal colour otherwise. Pure and side-effect free, so it is unit-tested directly.
    static func flashColor(for level: AccentLevel,
                           accent: FlashColor,
                           normal: FlashColor) -> FlashColor {
        level == .strong ? accent : normal
    }
}
