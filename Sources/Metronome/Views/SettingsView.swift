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
    /// The Songs library — the section builder launched from here saves the sequence into it, exactly as
    /// the Songs tab does.
    @ObservedObject var store: SongStore
    @Environment(\.dismiss) private var dismiss

    /// Which sections are expanded. All collapsed by default, so opening Settings shows a clean, labelled
    /// map of every group (with a one-line current-value summary under each).
    @State private var expanded: Set<SettingsSection> = []
    /// A fresh song being built via the "Sections" entry point. Non-nil presents the shared song builder;
    /// nothing persists unless the builder's Save is tapped, so cancelling leaves no orphan behind.
    @State private var buildingSong: Song?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        intro
                        ForEach(SettingsSection.allCases) { section in
                            // The section builder is a launcher, not a set of toggles — render it as a
                            // one-tap entry rather than an expand-then-act collapsible.
                            if section == .sections {
                                sectionBuilderLauncher
                            } else {
                                CollapsibleSection(title: section.title,
                                                   systemImage: section.systemImage,
                                                   subtitle: subtitle(for: section),
                                                   isExpanded: binding(for: section)) {
                                    content(for: section)
                                }
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
            .sheet(item: $buildingSong) { song in
                SongBuilderView(song: song, store: store, settings: settings)
                    .preferredColorScheme(.dark)
            }
        }
    }

    /// The discoverable entry point to the multi-section tempo-map builder. It reuses the *same* editor the
    /// Songs tab uses (`SongBuilderView` over `SongSection`/`Song`), so building a sequence isn't hidden
    /// behind the Songs library; saving from the builder drops the sequence into that library as usual.
    private var sectionBuilderLauncher: some View {
        Button {
            buildingSong = Song(name: "New Sequence", sections: [SongSection(name: "Section 1")])
        } label: {
            HStack(spacing: 14) {
                Image(systemName: SettingsSection.sections.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accentNormal)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build a section sequence")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Chain measures with their own tempo, meter & accents — saved to your Songs.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the section builder to chain measures with changing tempo and meter")
    }

    private var intro: some View {
        Text("Tempo, meter and sound live on the main screen. Everything else — and a builder for multi-section sequences — lives here. Tap a section to expand it.")
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
        case .sections:    EmptyView()   // rendered as a launcher in the section loop, not here
        case .voice:       voiceSection
        case .groove:      GrooveControlView(viewModel: viewModel)
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
        case .sections:    return ""      // the launcher supplies its own descriptive subtitle
        case .voice:       return soundSettings.speakSubdivisions ? "Counts subdivisions aloud" : "Beat numbers only"
        case .groove:      return grooveSummary
        case .accents:     return "\(viewModel.accents.count)-beat pattern"
        case .visuals:     return settings.indicatorStyle.displayName
        case .borderFlash: return settings.borderFlashEnabled ? "On" : "Off"
        case .gapTrainer:  return viewModel.trainer.isEnabled ? "On" : "Off"
        case .recents:     return recents.recents.isEmpty ? "None yet" : "\(recents.recents.count) saved"
        }
    }

    /// A one-line summary of the Groove section: swing amount and/or the active cell, or "Off".
    private var grooveSummary: String {
        let swingPct = Int((viewModel.swing * 100).rounded())
        var parts: [String] = []
        if swingPct > 0 { parts.append("Swing \(swingPct)%") }
        if viewModel.cell != .straight { parts.append(viewModel.cell.displayName) }
        return parts.isEmpty ? "Off" : parts.joined(separator: " · ")
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

            // Voice-sample credit. The clips are public domain (no attribution required); we credit the
            // source as a courtesy — see VoiceSampleFactory / tools/generate_voice_samples.py.
            Text(Self.voiceCredit)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Attribution for the bundled Voice clips (voice: en_US-ljspeech-high — LJ Speech dataset, public
    /// domain; Piper model trained by Bryce Beattie).
    static let voiceCredit = "Voice samples generated with Piper from the “LJ Speech” dataset "
        + "(public domain); model trained by Bryce Beattie."

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
