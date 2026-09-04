import SwiftUI

/// Edits a song: rename it, add / edit / delete / reorder its sections. Works on a local copy and
/// commits to the `SongStore` on Save, so Cancel discards.
struct SongBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SongStore

    @State private var song: Song
    @State private var editingSection: SongSection?

    init(song: Song, store: SongStore) {
        self.store = store
        _song = State(initialValue: song)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Song name", text: $song.name)
                        .font(.system(size: 18, weight: .semibold))
                }

                Section("Sections") {
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
        }
    }

    private func addSection() {
        let section = SongSection(name: "Section \(song.sections.count + 1)")
        song.sections.append(section)
        editingSection = section
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
