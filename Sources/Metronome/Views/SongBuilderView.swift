import SwiftUI

/// Edits a song: rename it, add / edit / delete / reorder its sections, and play it. Works on a local
/// copy and commits to the `SongStore` on Save (Cancel discards); Play commits first, then launches the
/// player so you can hear the piece while building it.
struct SongBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SongStore
    let settings: VisualSettingsStore

    @State private var song: Song
    @State private var editingSection: SongSection?
    @State private var playingSong: Song?

    init(song: Song, store: SongStore, settings: VisualSettingsStore) {
        self.store = store
        self.settings = settings
        _song = State(initialValue: song)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song name", text: $song.name)
                        .font(.system(size: 18, weight: .semibold))
                }

                Section {
                    ForEach(song.sections) { section in
                        Button { editingSection = section } label: {
                            SongSectionRow(section: section)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { song.sections.remove(atOffsets: $0) }
                    .onMove { song.sections.move(fromOffsets: $0, toOffset: $1) }

                    Button(action: addSection) {
                        Label("Add section", systemImage: "plus")
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Each section has its own tempo, meter, subdivision and accents. Tap to edit, swipe to delete, and use Edit to reorder. Sections play top to bottom.")
                }

                Section {
                    Button(action: play) {
                        Label("Play song", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(song.sections.isEmpty)
                }
            }
            .navigationTitle("Edit Song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { store.upsert(song); dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
            .sheet(item: $editingSection) { section in
                SongSectionEditorView(section: section) { updated in
                    if let index = song.sections.firstIndex(where: { $0.id == updated.id }) {
                        song.sections[index] = updated
                    }
                }
            }
            .fullScreenCover(item: $playingSong) { s in
                SongPlayView(song: s, settings: settings)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private func addSection() {
        let section = SongSection(name: "Section \(song.sections.count + 1)")
        song.sections.append(section)
        editingSection = section
    }

    /// Commit the current edits so the player reflects exactly what's on screen, then play.
    private func play() {
        store.upsert(song)
        playingSong = song
    }
}

private struct SongSectionRow: View {
    let section: SongSection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(section.tempoSummary) · \(section.meterAndFeel) · \(section.barsSummary)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
