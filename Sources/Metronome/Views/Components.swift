import SwiftUI

/// A rounded, filled tap target used for the tempo nudge / tap buttons.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A segmented-style toggle cell that reads as "selected" when `isOn`.
struct SelectableStyle: ButtonStyle {
    var isOn: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(isOn ? Theme.background : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isOn ? Theme.accentNormal : Theme.surfaceRaised)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A beat cell coloured by its accent state, shared by the metronome and song-section accent editors:
/// strong = accent colour, medium = secondary, normal = raised surface, muted = dim with a dashed
/// outline so it reads as intentionally silent. Tapping the button cycles the state.
struct BeatAccentCellStyle: ButtonStyle {
    var accent: BeatAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accent == .muted ? Theme.textSecondary.opacity(0.5) : Theme.stroke,
                                  style: StrokeStyle(lineWidth: 1, dash: accent == .muted ? [4, 3] : []))
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }

    private var fill: Color {
        switch accent {
        case .strong: return Theme.accentStrong
        case .medium: return Theme.accentMedium
        case .normal: return Theme.surfaceRaised
        case .muted:  return Theme.surface
        }
    }

    private var foreground: Color {
        switch accent {
        case .strong, .medium: return Theme.background
        case .normal:          return Theme.textPrimary
        case .muted:           return Theme.textSecondary
        }
    }
}

/// A titled container card.
struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke))
    }
}
