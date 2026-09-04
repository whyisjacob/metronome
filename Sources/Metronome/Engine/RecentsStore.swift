import Foundation

/// One saved entry in the Recents list — a full `MetronomeConfiguration` (including its BPM). Its
/// identity for the list is `config.settingsKey`, i.e. everything except tempo.
struct RecentSetting: Identifiable, Equatable, Codable {
    var id: UUID
    var config: MetronomeConfiguration

    init(id: UUID = UUID(), config: MetronomeConfiguration) {
        self.id = id
        self.config = config
    }
}

/// The Recents list: up to `maxCount` **unique** settings, most-recent first, persisted as JSON —
/// modelled on `SongStore` (injectable directory, atomic writes, silent IO failures).
///
/// Uniqueness is by `MetronomeConfiguration.settingsKey` — {time signature, subdivision, accents,
/// sound}, i.e. everything **except** BPM. The registration rule (`remember`) is deliberately precise:
///
///  - Changing **only BPM** (the new config's settings key matches the top entry's) updates the top
///    entry's stored BPM *in place* — no new entry, no reordering.
///  - Changing **any non-BPM field** registers a unique recent: if that exact settings key already
///    exists it moves to the top (with the new BPM); otherwise it is inserted on top. The list is then
///    capped at `maxCount`, dropping the oldest.
final class RecentsStore: ObservableObject {

    static let maxCount = 5

    @Published private(set) var recents: [RecentSetting] = []

    private let directory: URL
    private let fileName: String
    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    init(directory: URL? = nil, fileName: String = "recents.json") {
        self.directory = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { recents = []; return }
        var loaded = (try? JSONDecoder().decode([RecentSetting].self, from: data)) ?? []
        if loaded.count > Self.maxCount { loaded = Array(loaded.prefix(Self.maxCount)) }
        recents = loaded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(recents)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Match SongStore: persistence failures are intentionally silent in this cut.
        }
    }

    /// Registers `config` per the rules above. See the type doc for the full contract.
    func remember(_ config: MetronomeConfiguration) {
        let key = config.settingsKey

        // Only BPM (or nothing) changed relative to the current top → update that entry's BPM in place.
        if let top = recents.first, top.config.settingsKey == key {
            if recents[0].config.bpm != config.bpm {
                recents[0].config.bpm = config.bpm
                save()
            }
            return
        }

        // A non-BPM field changed. Drop any existing entry with this exact settings key (so a
        // re-selected config moves to the top rather than duplicating), then insert on top.
        recents.removeAll { $0.config.settingsKey == key }
        recents.insert(RecentSetting(config: config), at: 0)
        if recents.count > Self.maxCount {
            recents.removeLast(recents.count - Self.maxCount)
        }
        save()
    }

    func clear() {
        recents = []
        save()
    }
}
