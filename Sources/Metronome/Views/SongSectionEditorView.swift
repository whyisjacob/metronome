import SwiftUI

/// Edits one `SongSection` — tempo, time signature, subdivision, length (bars × repeats) and the
/// per-beat accent pattern. Holds each field in local state and reassembles a validated `SongSection`
/// (through its clamping initializer) on Save.
struct SongSectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let sectionID: UUID
    private let onSave: (SongSection) -> Void

    @State private var name: String
    @State private var tempo: Double
    @State private var numerator: Int
    @State private var denominator: Int
    @State private var subdivision: Subdivision
    @State private var bars: Int
    @State private var repeatCount: Int
    @State private var accents: [Bool]

    init(section: SongSection, onSave: @escaping (SongSection) -> Void) {
        self.sectionID = section.id
        self.onSave = onSave
        _name = State(initialValue: section.name)
        _tempo = State(initialValue: section.tempoBPM)
        _numerator = State(initialValue: section.timeSignature.numerator)
        _denominator = State(initialValue: section.timeSignature.denominator)
        _subdivision = State(initialValue: section.subdivision)
        _bars = State(initialValue: section.bars)
        _repeatCount = State(initialValue: section.repeatCount)
        _accents = State(initialValue: section.accentPattern)
    }

    private var beatCount: Int { max(1, numerator) }

    private var built: SongSection {
        SongSection(id: sectionID,
                    name: name,
                    tempoBPM: tempo,
                    timeSignature: TimeSignature(numerator: numerator, denominator: denominator),
                    subdivision: subdivision,
                    accentPattern: accents,
                    bars: bars,
                    repeatCount: repeatCount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Section name", text: $name)
                }

                Section("Tempo") {
                    HStack {
                        Text("\(Int(tempo.rounded())) BPM")
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                        Spacer()
                        Stepper("", value: $tempo, in: 30...300, step: 1).labelsHidden()
                    }
                    Slider(value: $tempo, in: 30...300, step: 1)
                }

                Section("Time signature") {
                    Stepper("Beats per bar: \(numerator)", value: $numerator, in: 1...16)
                        .onChange(of: numerator) { _, newValue in
                            accents = MetronomeConfiguration.normalizedAccents(accents, count: newValue)
                        }
                    Picker("Note value", selection: $denominator) {
                        ForEach(TimeSignature.allowedDenominators, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Subdivision") {
                    Picker("Subdivision", selection: $subdivision) {
                        ForEach(Subdivision.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Length") {
                    Stepper("Bars: \(bars)", value: $bars, in: 1...512)
                    Stepper("Repeat: ×\(repeatCount)", value: $repeatCount, in: 1...64)
                }

                Section("Accents") {
                    HStack(spacing: 6) {
                        ForEach(Array(0..<beatCount), id: \.self) { i in
                            Button { toggleAccent(i) } label: {
                                Text("\(i + 1)").frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(SelectableStyle(isOn: accents.indices.contains(i) && accents[i]))
                        }
                    }
                }
            }
            .navigationTitle("Edit Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(built); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func toggleAccent(_ i: Int) {
        var updated = MetronomeConfiguration.normalizedAccents(accents, count: beatCount)
        if updated.indices.contains(i) { updated[i].toggle() }
        // Re-normalize so the downbeat is never left silent-by-omission.
        accents = MetronomeConfiguration.normalizedAccents(updated, count: beatCount)
    }
}
