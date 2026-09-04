import SwiftUI

/// The grouped settings area, presented as a sheet from the metronome screen so the main screen stays
/// clean. Holds the pieces that don't belong in the primary flow: the visual indicator style, the
/// screen-border flash (toggle + its two user-selectable colours), the per-beat accent pattern, and a
/// note on the Voice / sound options.
struct SettingsView: View {
    @ObservedObject var settings: VisualSettingsStore
    @ObservedObject var viewModel: MetronomeViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        stylePicker
                        borderFlash
                        AccentRowView(viewModel: viewModel)
                        voiceNote
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Visual indicator

    private var stylePicker: some View {
        Card("Visual indicator") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(BeatIndicatorStyle.allCases) { style in
                    Button { settings.setIndicatorStyle(style) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: style.symbolName)
                                .font(.system(size: 20, weight: .semibold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.displayName)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(style.caption)
                                    .font(.system(size: 11))
                                    .foregroundStyle(settings.indicatorStyle == style
                                                     ? Theme.background.opacity(0.7) : Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(SelectableStyle(isOn: settings.indicatorStyle == style))
                }
            }
        }
    }

    // MARK: - Border flash

    private var borderFlash: some View {
        Card("Screen border flash") {
            Toggle(isOn: Binding(get: { settings.borderFlashEnabled },
                                 set: { settings.setBorderFlashEnabled($0) })) {
                Text("Flash the screen edge on each beat")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(Theme.start)

            if settings.borderFlashEnabled {
                colorRow(title: "Accent beat", selected: settings.accentFlashColor,
                         onSelect: settings.setAccentFlashColor)
                colorRow(title: "Normal beat", selected: settings.normalFlashColor,
                         onSelect: settings.setNormalFlashColor)
            } else {
                Text("Distinct colours for accented (downbeat) vs normal beats.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func colorRow(title: String,
                          selected: FlashColor,
                          onSelect: @escaping (FlashColor) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 10)], spacing: 10) {
                ForEach(FlashColor.allCases) { c in
                    Button { onSelect(c) } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Theme.textPrimary, lineWidth: selected == c ? 3 : 0))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.displayName)
                }
            }
        }
    }

    // MARK: - Voice note

    private var voiceNote: some View {
        Card("Voice & sounds") {
            Text("Pick a click timbre or Voice (spoken count) from Sound on the main screen. Voice speaks each beat number and the e / and / a subdivision syllables.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
