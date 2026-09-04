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
    @State private var accents: [BeatAccent]

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

    private var timeSig: TimeSignature { TimeSignature(numerator: numerator, denominator: denominator) }
    /// Main beats (pulses) per bar — compound-aware, so 6/8 edits 2 beats, not 6.
    private var beatCount: Int { max(1, timeSig.beatsPerBar) }
    private var subdivisionOptions: [Subdivision] {
        timeSig.isCompound ? Subdivision.compoundCases : Subdivision.allCases
    }

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
                        .onChange(of: numerator) { _, _ in meterChanged() }
                    Picker("Note value", selection: $denominator) {
                        ForEach(TimeSignature.allowedDenominators, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: denominator) { _, _ in meterChanged() }
                    if timeSig.isCompound {
                        Text("Compound meter: felt in \(beatCount) — the beat is a dotted quarter.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }

                Section("Subdivision") {
                    Picker("Subdivision", selection: $subdivision) {
                        ForEach(subdivisionOptions) { s in
                            Text(timeSig.isCompound ? s.compoundDisplayName : s.displayName).tag(s)
                        }
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
                            Button { cycleAccent(i) } label: {
                                Text("\(i + 1)").frame(maxWidth: .infinity, minHeight: 38)
                            }
                            .buttonStyle(BeatAccentCellStyle(accent: accentAt(i)))
                        }
                    }
                    Text("Tap to cycle: Accent → Medium → Normal → Muted.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
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

    private func accentAt(_ i: Int) -> BeatAccent { accents.indices.contains(i) ? accents[i] : .normal }

    /// Cycles beat `i` to its next accent state (strong → medium → normal → muted → strong).
    private func cycleAccent(_ i: Int) {
        var updated = MetronomeConfiguration.normalizedAccents(accents, count: beatCount)
        if updated.indices.contains(i) { updated[i] = updated[i].next }
        // Re-normalize so the downbeat is never left accent-less by omission.
        accents = MetronomeConfiguration.normalizedAccents(updated, count: beatCount)
    }

    /// Keeps the accent array and subdivision consistent after a meter edit: resize the pattern to the
    /// new main-beat count, and drop a now-invalid subdivision (e.g. a simple-meter triplet) when the
    /// meter has become compound.
    private func meterChanged() {
        accents = MetronomeConfiguration.normalizedAccents(accents, count: beatCount)
        if timeSig.isCompound && !Subdivision.compoundCases.contains(subdivision) {
            subdivision = .quarter
        }
    }
}
