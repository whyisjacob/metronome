import SwiftUI

/// One expandable/collapsible group on the unified Settings screen — the accordion cell. The header
/// shows the section name, an icon, and (when collapsed) a one-line summary of the current value, so a
/// user can see at a glance what each section holds and what it is set to without opening it. Tapping the
/// header toggles its content; several sections can be open at once (expand only what you want to change).
///
/// Styled to match the app's `Card`, so the Settings screen reads as one consistent surface.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let systemImage: String
    /// A short current-value summary shown under the title while collapsed (e.g. the chosen sound).
    let subtitle: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accentNormal)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if let subtitle, !subtitle.isEmpty, !isExpanded {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle ?? "")
            .accessibilityHint(isExpanded ? "Expanded. Double-tap to collapse." : "Collapsed. Double-tap to expand.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke))
    }
}
