import SwiftUI

/// Edits one `SongSection`. Crucially it does NOT re-implement tempo / meter / subdivision / accents /
/// groove — it drives a transient `MetronomeViewModel` (seeded from the section) with the **exact same**
/// control components the main screen uses (`TempoControlView`, `MeterControlView`, `SubdivisionControlView`,
/// `AccentRowView`, `GrooveControlView`), then reads the edited configuration back on Save. So there is
/// exactly ONE implementation of each of those controls in the app, and editing a section looks and behaves
/// identically to editing the main metronome. Only the section-specific fields (name, bars, repeats) are
/// local to this screen.
struct SongSectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let sectionID: UUID
    /// The section's pickup, carried through unchanged (this screen has no pickup control yet). `built`
    /// re-emits it so an edit never drops it, and the `SongSection` initializer re-clamps it if a
    /// meter/subdivision change here shrinks the bar.
    private let pickupTicks: Int
    /// Called on EVERY change to the working section, so edits are committed to the song continuously and
    /// an in-progress edit survives a force-quit (the builder autosaves each one). See P2.6.
    private let onCommit: (SongSection) -> Void
    /// Called when the user taps Cancel, so the builder can restore the pre-edit snapshot (Cancel must undo
    /// the live-committed changes).
    private let onCancel: () -> Void

    /// A throwaway metronome model the shared controls bind to. Never played (its engine is never started);
    /// it is purely the edit surface, so the section round-trips through the same value type the main screen
    /// edits (`MetronomeConfiguration`).
    @StateObject private var editVM: MetronomeViewModel
    @State private var name: String
    @State private var bars: Int
    @State private var repeatCount: Int

    init(section: SongSection,
         onCommit: @escaping (SongSection) -> Void,
         onCancel: @escaping () -> Void) {
        self.sectionID = section.id
        self.pickupTicks = section.pickupTicks
        self.onCommit = onCommit
        self.onCancel = onCancel
        _editVM = StateObject(wrappedValue: MetronomeViewModel(config: section.configuration))
        _name = State(initialValue: section.name)
        _bars = State(initialValue: section.bars)
        _repeatCount = State(initialValue: section.repeatCount)
    }

    /// The edited section — the shared controls' `MetronomeConfiguration` plus this screen's name/length,
    /// keeping the original identity.
    private var built: SongSection {
        let c = editVM.config
        return SongSection(id: sectionID, name: name, tempoBPM: c.bpm,
                           timeSignature: c.timeSignature, subdivision: c.subdivision,
                           accentPattern: c.accents, bars: bars, repeatCount: repeatCount,
                           swing: c.swing, cell: c.cell, pickupTicks: pickupTicks)
    }

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
