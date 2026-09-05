import SwiftUI

/// The song library: saved songs as app-styled cards. Tap a card to edit; tap ▶ to play (on the SAME
/// metronome — playback opens the Metronome tab, never a separate player). Add with +, duplicate/delete
/// from each card's menu. Styled with the app's `Card`/`Theme`/`ScrollView` idiom to match every other
/// screen (no system `List`).
struct SongLibraryView: View {
    @ObservedObject var store: SongStore
    @ObservedObject var metronome: MetronomeViewModel

    @State private var editingSong: Song?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    if store.songs.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 12) {
                            ForEach(store.songs) { song in
                                SongCard(song: song,
                                         onEdit: { editingSong = song },
                                         onPlay: { metronome.playSong(song) },
                                         onDuplicate: { store.upsert(song.duplicated()) },
                                         onDelete: { store.delete(song) })
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                    }
                }
            }
            .navigationTitle("Songs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: addSong) { Image(systemName: "plus") }
                        .accessibilityLabel("Add song")
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .sheet(item: $editingSong) { song in
                SongBuilderView(song: song, store: store, metronome: metronome)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 42))
                .foregroundStyle(Theme.textSecondary)
            Text("No songs yet")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Tap + to build a tempo-map — sections whose tempo, meter, subdivision and groove change through the piece. Or tap the bookmark on the Metronome screen to save your current settings as a song.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func addSong() {
        let song = Song(name: "New Song", sections: [SongSection(name: "Section 1")])
        store.upsert(song)
        editingSong = song
    }
}

/// One library row as an app card: title + summary + a big Play button, with a menu for duplicate/delete.
private struct SongCard: View {
    let song: Song
    let onEdit: () -> Void
    let onPlay: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { onEdit() } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("More actions for \(song.name)")

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(song.sections.isEmpty ? Theme.beatIdle : Theme.start)
            }
            .buttonStyle(.plain)
            .disabled(song.sections.isEmpty)
            .accessibilityLabel("Play \(song.name)")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke))
    }

    private var summary: String {
        let sectionWord = song.sections.count == 1 ? "section" : "sections"
        return "\(song.sections.count) \(sectionWord) · \(song.totalBars) bars · \(Self.duration(song))"
    }

    private static func duration(_ song: Song) -> String {
        let total = Int(song.durationSeconds.rounded())
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
    }
}
