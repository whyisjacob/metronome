import SwiftUI

/// The song library: lists saved songs, adds new ones, and launches edit / play. Reordering and
/// deletion are available via the standard edit mode. Each row makes both actions obvious — tap the
/// title to edit, tap the green button to play.
struct SongLibraryView: View {
    @ObservedObject var store: SongStore
    @ObservedObject var settings: VisualSettingsStore
    @State private var editingSong: Song?
    @State private var playingSong: Song?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Songs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.songs.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: addSong) { Image(systemName: "plus") }
                        .accessibilityLabel("Add song")
                }
            }
            .sheet(item: $editingSong) { song in
                SongBuilderView(song: song, store: store, settings: settings)
                    .preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $playingSong) { song in
                SongPlayView(song: song, settings: settings)
                    .preferredColorScheme(.dark)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.songs.isEmpty {
            emptyState
        } else {
            List {
                ForEach(store.songs) { song in
                    SongRow(song: song,
                            onEdit: { editingSong = song },
                            onPlay: { playingSong = song })
                        .listRowBackground(Theme.surface)
                }
                .onDelete { store.delete(at: $0) }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 42))
                .foregroundStyle(Theme.textSecondary)
            Text("No songs yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Tap + to build a tempo-map — sections whose tempo and time signature change through the piece. Or tap the bookmark on the Metronome screen to save your current settings as a song.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private func addSong() {
        let song = Song(name: "New Song", sections: [SongSection(name: "Section 1")])
        store.upsert(song)
        editingSong = song
    }
}

private struct SongRow: View {
    let song: Song
    let onEdit: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(song.sections.count) section\(song.sections.count == 1 ? "" : "s") · \(song.totalBars) bars")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(song.sections.isEmpty ? Theme.beatIdle : Theme.start)
            }
            .buttonStyle(.plain)
            .disabled(song.sections.isEmpty)
            .accessibilityLabel("Play \(song.name)")
        }
        .padding(.vertical, 4)
    }
}
