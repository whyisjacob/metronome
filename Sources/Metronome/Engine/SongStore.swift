import Foundation

/// The song library's tiny persistence layer: an in-memory, observable list of `Song`s backed by a
/// single JSON file. Kept deliberately small and dependency-free (Foundation `Data` + `JSONEncoder`)
/// so it is trivially unit-testable — the storage directory is injectable, so tests write to a temp
/// folder instead of the real Documents directory.
///
/// Not `@MainActor`-isolated on purpose: it is a plain value store used from the main thread by the
/// UI and driven synchronously by tests. Writes are atomic; IO errors are swallowed in this v2 cut
/// (surfacing them is future work).
final class SongStore: ObservableObject {

    @Published private(set) var songs: [Song] = []

    private let directory: URL
    private let fileName: String
    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// - Parameters:
    ///   - directory: where `songs.json` lives. Defaults to the app's Documents directory.
    ///   - fileName: overridable for tests.
    init(directory: URL? = nil, fileName: String = "songs.json") {
        self.directory = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        load()
    }

    /// Replaces the in-memory list with what is on disk (empty if the file is missing or unreadable).
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            songs = []
            return
        }
        songs = (try? JSONDecoder().decode([Song].self, from: data)) ?? []
    }

    /// Writes the current list to disk atomically. Creates the directory if needed.
    func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(songs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // v2: intentionally silent. Persistence failures surface as "changes not saved".
        }
    }

    /// Inserts a new song or replaces the existing one with the same `id`, then persists.
    func upsert(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs[index] = song
        } else {
            songs.append(song)
        }
        save()
    }

    func delete(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        songs.remove(atOffsets: offsets)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        songs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func song(withID id: UUID) -> Song? { songs.first { $0.id == id } }
}
