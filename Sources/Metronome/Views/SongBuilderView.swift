import SwiftUI

/// Builds / edits a song: rename it, and add / edit / reorder / duplicate / delete its sections, then
/// play. Works on a local copy and commits to the `SongStore` on Save (Cancel discards). Play commits
/// first, then starts the song on the SHARED metronome (the app reveals the Metronome tab) — there is no
/// separate player. Styled with the app's `Card`/`Theme` idiom to match the rest of the app.
struct SongBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SongStore
    @ObservedObject var metronome: MetronomeViewModel

    @State private var song: Song
    @State private var editingSection: SongSection?

    init(song: Song, store: SongStore, metronome: MetronomeViewModel) {
        self.store = store
        self.metronome = metronome
        _song = State(initialValue: song)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        nameCard
                        sectionsCard
                        playButton
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Edit Song")
            .navigationBarTitleDisplayMode(.inline)
            .foregroundStyle(Theme.textPrimary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { store.upsert(song); dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(item: $editingSection) { section in
                SongSectionEditorView(section: section) { updated in
                    if let i = song.sections.firstIndex(where: { $0.id == updated.id }) {
                        song.sections[i] = updated
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Name

    private var nameCard: some View {
        Card("Song name") {
            TextField("Song name", text: $song.name)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Sections

    private var sectionsCard: some View {
        Card("Sections") {
            if song.sections.isEmpty {
                Text("Add a section to begin. Each section has its own tempo, meter, subdivision, accents and groove, played for a set number of bars.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(song.sections.enumerated()), id: \.element.id) { entry in
                        let index = entry.offset
                        let section = entry.element
                        SectionRow(index: index,
                                   count: song.sections.count,
                                   section: section,
                                   onEdit: { editingSection = section },
                                   onMoveUp: { move(index, by: -1) },
                                   onMoveDown: { move(index, by: 1) },
                                   onDuplicate: { duplicate(index) },
                                   onDelete: { delete(index) })
                    }
                }
                Text(totalSummary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }

            Button(action: addSection) {
                Label("Add section", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    private var playButton: some View {
        Button(action: play) {
            Label("Play song", systemImage: "play.fill")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(SelectableStyle(isOn: !song.sections.isEmpty))
        .disabled(song.sections.isEmpty)
    }

    private var totalSummary: String {
        "\(song.sections.count) sections · \(song.totalBars) bars total"
    }

    // MARK: - Actions

    private func addSection() {
        let section = SongSection(name: "Section \(song.sections.count + 1)")
        song.sections.append(section)
        editingSection = section
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard song.sections.indices.contains(index), song.sections.indices.contains(target) else { return }
        song.sections.swapAt(index, target)
    }

    private func duplicate(_ index: Int) {
        guard song.sections.indices.contains(index) else { return }
        var copy = song.sections[index]
        copy = SongSection(id: UUID(), name: copy.name + " copy", tempoBPM: copy.tempoBPM,
                           timeSignature: copy.timeSignature, subdivision: copy.subdivision,
                           accentPattern: copy.accentPattern, bars: copy.bars, repeatCount: copy.repeatCount,
                           swing: copy.swing, cell: copy.cell)
        song.sections.insert(copy, at: index + 1)
    }

    private func delete(_ index: Int) {
        guard song.sections.indices.contains(index) else { return }
        song.sections.remove(at: index)
    }

    /// Commit the current edits so playback reflects exactly what's on screen, then start on the shared
    /// metronome and dismiss — `RootView` reveals the Metronome tab (via `songLaunchNonce`).
    private func play() {
        store.upsert(song)
        metronome.playSong(song)
        dismiss()
    }
}

/// One section as an app card: its name + summary, tap to edit, with move up/down and a duplicate/delete
/// menu. Up/down make reordering obvious without a hidden "edit mode".
private struct SectionRow: View {
    let index: Int
    let count: Int
    let section: SongSection
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(section.tempoSummary) · \(section.meterAndFeel) · \(section.barsSummary)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 22)
                }
                .disabled(index == 0)
                .accessibilityLabel("Move \(section.name) up")
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 22)
                }
                .disabled(index == count - 1)
                .accessibilityLabel("Move \(section.name) down")
            }
            .foregroundStyle(Theme.textSecondary)

            Menu {
                Button { onEdit() } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 36, height: 40)
            }
            .accessibilityLabel("More actions for \(section.name)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
    }
}
