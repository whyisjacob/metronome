import SwiftUI

/// Edits one `SongSection`. Crucially it does NOT re-implement tempo / meter / subdivision / accents /
/// groove — it drives a transient `MetronomeViewModel` (seeded from the section) with the **exact same**
/// control components the main screen uses (`TempoControlView`, `MeterControlView`, `SubdivisionControlView`,
/// `AccentRowView`, `GrooveControlView`, `CountInControlView`), then reads the edited configuration back on
/// Save. So there is exactly ONE implementation of each of those controls in the app, and editing a section
/// looks and behaves identically to editing the main metronome. Only the section-specific fields (name,
/// bars, repeats, start-with-pickup choice, Voice overrides) are local to this screen.
struct SongSectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let sectionID: UUID
    /// The song's global Voice default + the app's speak-subdivisions preference, so the Voice card can show
    /// what "Inherit" currently resolves to ("Inherit (on)" vs "Inherit (off)").
    private let songVoiceEnabled: Bool
    private let globalSpeakSubdivisions: Bool
    /// Called on EVERY change to the working section, so edits are committed to the song continuously and
    /// an in-progress edit survives a force-quit (the builder autosaves each one). See P2.6.
    private let onCommit: (SongSection) -> Void
    /// Called when the user taps Cancel, so the builder can restore the pre-edit snapshot (Cancel must undo
    /// the live-committed changes).
    private let onCancel: () -> Void

    /// A throwaway metronome model the shared controls bind to. Never played (its engine is never started);
    /// it is purely the edit surface, so the section round-trips through the same value type the main screen
    /// edits (`MetronomeConfiguration`) — including the count-in (`CountInControlView`), which is denominated
    /// in this section's own grid because the model is seeded from the section's configuration.
    @StateObject private var editVM: MetronomeViewModel
    @State private var name: String
    @State private var bars: Int
    @State private var repeatCount: Int
    /// Whether this section's count-in plays when you start on / jump to it (the user's per-section choice).
    @State private var startWithPickup: Bool
    /// Per-section Voice overrides (`nil` = inherit the song/app global). Threaded into `built`.
    @State private var voiceOverride: Bool?
    @State private var speakSubdivisionsOverride: Bool?

    init(section: SongSection,
         songVoiceEnabled: Bool = false,
         globalSpeakSubdivisions: Bool = true,
         onCommit: @escaping (SongSection) -> Void,
         onCancel: @escaping () -> Void) {
        self.sectionID = section.id
        self.songVoiceEnabled = songVoiceEnabled
        self.globalSpeakSubdivisions = globalSpeakSubdivisions
        self.onCommit = onCommit
        self.onCancel = onCancel
        // Seed the throwaway model from the section AND its count-in, so the shared `CountInControlView`
        // shows/edits this section's pickup in its own grid. The model is never started.
        _editVM = StateObject(wrappedValue: {
            let vm = MetronomeViewModel(config: section.configuration)
            vm.setPickupTicks(section.pickupTicks)
            return vm
        }())
        _name = State(initialValue: section.name)
        _bars = State(initialValue: section.bars)
        _repeatCount = State(initialValue: section.repeatCount)
        _startWithPickup = State(initialValue: section.startWithPickup)
        _voiceOverride = State(initialValue: section.voiceEnabled)
        _speakSubdivisionsOverride = State(initialValue: section.speakSubdivisions)
    }

    /// The edited section — the shared controls' `MetronomeConfiguration` plus this screen's name/length,
    /// count-in and Voice overrides, keeping the original identity. The count-in is read back from the shared
    /// model (`editVM.pickupTicks`), which the count-in control edits and which re-clamps automatically when
    /// the meter/subdivision change here.
    private var built: SongSection {
        let c = editVM.config
        return SongSection(id: sectionID, name: name, tempoBPM: c.bpm,
                           timeSignature: c.timeSignature, subdivision: c.subdivision,
                           accentPattern: c.accents, bars: bars, repeatCount: repeatCount,
                           swing: c.swing, cell: c.cell, pickupTicks: editVM.pickupTicks,
                           startWithPickup: startWithPickup,
                           voiceEnabled: voiceOverride, speakSubdivisions: speakSubdivisionsOverride)
    }

    /// What Voice resolves to for this section right now (its override, or the inherited song global).
    private var effectiveVoiceOn: Bool { voiceOverride ?? songVoiceEnabled }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        Card("Section name") {
                            TextField("Section name", text: $name)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.textPrimary)
                        }

                        // The SAME components the main screen uses — no parallel implementations.
                        Card("Tempo") { TempoControlView(viewModel: editVM) }
                        MeterControlView(viewModel: editVM)          // already a titled Card
                        SubdivisionControlView(viewModel: editVM)    // already a titled Card
                        Card("Accents") { AccentRowView(viewModel: editVM) }
                        Card("Groove") { GrooveControlView(viewModel: editVM) }

                        // Count-in: the SAME shared control as the main screen, in this section's grid.
                        Card("Count-in") {
                            CountInControlView(viewModel: editVM)
                            if editVM.pickupTicks > 0 {
                                Toggle(isOn: $startWithPickup) {
                                    Text("Play when starting or jumping here")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                .tint(Theme.accentNormal)
                                Text("A pickup is a one-time lead-in when you START on or SEEK to this section. It is never replayed on a continuous pass through the song.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        voiceCard

                        Card("Length") {
                            LengthStepper(title: "Bars", value: bars, range: SongSection.barsRange,
                                          format: { "\($0)" }, onChange: { bars = $0 })
                            LengthStepper(title: "Repeat", value: repeatCount, range: SongSection.repeatRange,
                                          format: { "×\($0)" }, onChange: { repeatCount = $0 })
                            Text("This section plays \(bars) bar\(bars == 1 ? "" : "s")"
                                 + (repeatCount > 1 ? ", \(repeatCount) times (\(bars * repeatCount) bars)." : "."))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Edit Section")
            .navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(Theme.textPrimary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onCancel(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onCommit(built); dismiss() }.fontWeight(.semibold)
                }
            }
            // Commit continuously so a force-quit mid-edit never reverts the section to its just-added
            // defaults (P2.6). Each change flows to the song, which autosaves; Cancel restores the snapshot.
            .onChange(of: built) { _, updated in onCommit(updated) }
        }
    }

    // MARK: - Voice / counting (per-section, inheriting the song global)

    private var voiceCard: some View {
        Card("Voice / counting") {
            InheritSegmentedRow(title: "COUNT OUT LOUD", selection: $voiceOverride, inherited: songVoiceEnabled)
            if effectiveVoiceOn {
                InheritSegmentedRow(title: "SPEAK SUBDIVISIONS",
                                    selection: $speakSubdivisionsOverride, inherited: globalSpeakSubdivisions)
                Text("Counts this section's beats aloud (its subdivision is the counted subdivision). \u{201C}Inherit\u{201D} follows the song's global Voice setting.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This section clicks. Set \u{201C}Count out loud\u{201D} to On (or turn the song's global Voice on) to count it aloud.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A three-way Inherit / On / Off segmented control over an optional `Bool` (`nil` == inherit). Used for the
/// per-section Voice overrides; ONE implementation, reused for both, showing what "Inherit" resolves to.
private struct InheritSegmentedRow: View {
    let title: String
    @Binding var selection: Bool?
    /// The value inherited when `selection == nil`, shown on the Inherit segment.
    let inherited: Bool

    private enum Choice: Hashable { case inherit, on, off }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch selection {
                case .none: return .inherit
                case .some(true): return .on
                case .some(false): return .off
                }
            },
            set: {
                switch $0 {
                case .inherit: selection = nil
                case .on:      selection = true
                case .off:     selection = false
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            Picker(title, selection: choice) {
                Text("Inherit (\(inherited ? "on" : "off"))").tag(Choice.inherit)
                Text("On").tag(Choice.on)
                Text("Off").tag(Choice.off)
            }
            .pickerStyle(.segmented)
        }
    }
}

/// A compact −/value/+ stepper for the section's bars/repeats (section-specific fields the main screen has
/// no equivalent of), in the app's pill style.
private struct LengthStepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(action: { onChange(max(range.lowerBound, value - 1)) }) {
                Image(systemName: "minus").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Fewer \(title)")

            Text(format(value))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(minWidth: 56)
                .monospacedDigit()

            Button(action: { onChange(min(range.upperBound, value + 1)) }) {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(value >= range.upperBound)
            .accessibilityLabel("More \(title)")
        }
    }
}
