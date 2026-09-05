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
    private let onSave: (SongSection) -> Void

    /// A throwaway metronome model the shared controls bind to. Never played (its engine is never started);
    /// it is purely the edit surface, so the section round-trips through the same value type the main screen
    /// edits (`MetronomeConfiguration`).
    @StateObject private var editVM: MetronomeViewModel
    @State private var name: String
    @State private var bars: Int
    @State private var repeatCount: Int

    init(section: SongSection, onSave: @escaping (SongSection) -> Void) {
        self.sectionID = section.id
        self.onSave = onSave
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
                           swing: c.swing, cell: c.cell)
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
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(built); dismiss() }.fontWeight(.semibold)
                }
            }
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
