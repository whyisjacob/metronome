import Foundation

/// The information-architecture contract for the whole app: *every* user-facing control, and where it
/// lives. This is the single source of truth that both the unified Settings screen is built from and the
/// "nothing is stranded" test checks against — so a control can never silently end up orphaned between
/// the main screen and Settings, and the user never has to wonder which page a setting is on.
///
/// If you add a control, add a case here and give it a `placement`; the `SettingsCatalogTests` guard
/// fails until it is placed, and (for a Settings control) rendered under its section.
enum AppControl: String, CaseIterable {
    // Absolute base — the things you touch constantly, kept on the main screen.
    case tempo              // BPM readout, slider, ±1 nudges, tap tempo
    case transport          // Start / Stop
    case timeSignature      // meter (numerator/denominator, groupings)
    case subdivision        // quarter / eighth / triplet / sixteenth / 32nd
    case beatVisual         // the on-screen beat indicator

    // Everything else — consolidated into the single collapsible Settings screen.
    case sound              // click timbre + Voice mode
    case voiceCounting      // Voice: speak subdivisions aloud
    case swing              // swing / shuffle amount
    case rhythmCell         // idiomatic sixteenth-grid pattern picker
    case accents            // per-beat accent pattern
    case visualIndicator    // which beat-indicator style is shown
    case borderFlash        // screen-edge flash toggle + colours
    case gapTrainer         // gap-click practice trainer
    case recents            // quick-recall of recent settings
}

/// The collapsible groups on the unified Settings screen, in display order. The screen renders exactly
/// these, and every non-base `AppControl` maps to one of them.
enum SettingsSection: String, CaseIterable, Identifiable {
    case sound
    case voice
    case groove
    case accents
    case visuals
    case borderFlash
    case gapTrainer
    case recents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound:       return "Sound"
        case .voice:       return "Voice"
        case .groove:      return "Groove"
        case .accents:     return "Accents"
        case .visuals:     return "Visuals"
        case .borderFlash: return "Border flash"
        case .gapTrainer:  return "Gap trainer"
        case .recents:     return "Recents"
        }
    }

    /// SF Symbol shown on the section header.
    var systemImage: String {
        switch self {
        case .sound:       return "speaker.wave.2.fill"
        case .voice:       return "person.wave.2.fill"
        case .groove:      return "waveform.path"
        case .accents:     return "chart.bar.fill"
        case .visuals:     return "circle.circle.fill"
        case .borderFlash: return "rectangle.inset.filled.and.person.filled"
        case .gapTrainer:  return "figure.walk.motion"
        case .recents:     return "clock.arrow.circlepath"
        }
    }
}

/// Where a control is surfaced: the always-visible main screen, or a specific Settings section.
enum ControlPlacement: Equatable {
    case mainScreen
    case settings(SettingsSection)
}

extension AppControl {
    /// The one place this control lives. Exhaustive by construction — the compiler forces every control
    /// to declare a home, and the test asserts the base set and that no section is left empty.
    var placement: ControlPlacement {
        switch self {
        case .tempo, .transport, .timeSignature, .subdivision, .beatVisual:
            return .mainScreen
        case .sound:           return .settings(.sound)
        case .voiceCounting:   return .settings(.voice)
        case .swing:           return .settings(.groove)
        case .rhythmCell:      return .settings(.groove)
        case .accents:         return .settings(.accents)
        case .visualIndicator: return .settings(.visuals)
        case .borderFlash:     return .settings(.borderFlash)
        case .gapTrainer:      return .settings(.gapTrainer)
        case .recents:         return .settings(.recents)
        }
    }
}
