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
