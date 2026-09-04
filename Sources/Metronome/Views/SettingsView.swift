import SwiftUI

/// The single, unified Settings screen. Everything that isn't the main-screen base (tempo, meter,
/// subdivision, start/stop, and the beat visual) lives here, grouped into clearly-labelled collapsible
/// sections — so a user expands only what they want to change and never has to wonder which page a
/// setting is on. The section list is driven by `SettingsSection.allCases` and mirrors `AppControl`'s
/// placement, so a control can't be added without getting a home here (enforced by `SettingsCatalogTests`).
struct SettingsView: View {
    @ObservedObject var settings: VisualSettingsStore
    @ObservedObject var viewModel: MetronomeViewModel
    @ObservedObject var soundSettings: SoundSettingsStore
    @ObservedObject var recents: RecentsStore
    @Environment(\.dismiss) private var dismiss

    /// Which sections are expanded. All collapsed by default, so opening Settings shows a clean, labelled
    /// map of every group (with a one-line current-value summary under each).
    @State private var expanded: Set<SettingsSection> = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        intro
                        ForEach(SettingsSection.allCases) { section in
                            CollapsibleSection(title: section.title,
                                               systemImage: section.systemImage,
                                               subtitle: subtitle(for: section),
                                               isExpanded: binding(for: section)) {
                                content(for: section)
                            }
                        }
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

    private var intro: some View {
        Text("Everything beyond tempo, meter and Start lives here. Tap a section to expand it.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
    }

    // MARK: - Section plumbing

    private func binding(for section: SettingsSection) -> Binding<Bool> {
        Binding(get: { expanded.contains(section) },
                set: { isOn in
                    if isOn { expanded.insert(section) } else { expanded.remove(section) }
                })
    }

    @ViewBuilder private func content(for section: SettingsSection) -> some View {
        switch section {
        case .sound:       SoundControlView(viewModel: viewModel)
        case .voice:       voiceSection
        case .accents:     AccentRowView(viewModel: viewModel)
        case .visuals:     visualsSection
        case .borderFlash: borderFlashSection
        case .gapTrainer:  TrainerControlView(viewModel: viewModel)
        case .recents:     RecentsBar(recents: recents) { viewModel.load($0) }
        }
    }

    /// The collapsed one-line summary of the current value, so the section list doubles as an at-a-glance
    /// status of every setting.
    private func subtitle(for section: SettingsSection) -> String {
        switch section {
        case .sound:       return viewModel.sound.displayName
        case .voice:       return soundSettings.speakSubdivisions ? "Counts subdivisions aloud" : "Beat numbers only"
        case .accents:     return "\(viewModel.accents.count)-beat pattern"
        case .visuals:     return settings.indicatorStyle.displayName
        case .borderFlash: return settings.borderFlashEnabled ? "On" : "Off"
        case .gapTrainer:  return viewModel.trainer.isEnabled ? "On" : "Off"
        case .recents:     return recents.recents.isEmpty ? "None yet" : "\(recents.recents.count) saved"
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { soundSettings.speakSubdivisions },
                                 set: { viewModel.setSpeakSubdivisions($0) })) {
                Text("Count subdivisions aloud")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(Theme.start)

            Text(voiceExplainer)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.sound != .voice {
                Button { viewModel.setSound(.voice) } label: {
                    Text("Use the Voice sound")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    private var voiceExplainer: String {
        if viewModel.sound == .voice {
            return soundSettings.speakSubdivisions
                ? "Voice is on. It speaks the beat numbers and the in-between syllables — “1 e and a” on sixteenths. At very fast tempos it speaks only the beat numbers and clicks the subdivisions."
                : "Voice is on. It speaks only the main beat numbers; the in-between subdivisions click."
        } else {
            return "Choose the Voice sound to hear the beat counted aloud. This switch controls whether it also speaks the in-between subdivisions."
        }
    }

    // MARK: - Visuals (beat indicator style)

    private var visualsSection: some View {
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

    // MARK: - Border flash

    private var borderFlashSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
}
