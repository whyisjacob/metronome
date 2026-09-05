import Foundation

/// The song library's tiny persistence layer: an in-memory, observable list of `Song`s backed by a
/// single JSON file. Kept deliberately small and dependency-free (Foundation `Data` + `JSONEncoder`)
/// so it is trivially unit-testable — the storage directory is injectable, so tests write to a temp
/// folder instead of the real Documents directory.
///
/// Not `@MainActor`-isolated on purpose: it is a plain value store used from the main thread by the
/// UI and driven synchronously by tests. Writes are atomic and synchronous, so a change is on disk before
/// the call returns (it survives app termination, not just backgrounding).
///
/// ## Data-safety contract (P1) — a corrupt songs file must never wipe the library
/// A hand-entered song a musician is afraid of losing is the whole point of this store, so both directions
/// of I/O fail *loud and safe*:
///
///  * **Writes** are surfaced, not swallowed: `saveDidFail` flips true so the UI can warn "changes not
///    saved", and `save()` returns success.
///  * **Reads** distinguish an absent file (a legitimately empty library) from a *present but undecodable*
///    one (an error state — NOT an empty library). On a decode failure the store:
///      1. copies the unreadable bytes aside to `songs-corrupt-<ISO8601>.json` (never destroys them),
///      2. tries to auto-recover from the rolling `songs.bak.json` backup and, if it decodes, restores it
///         and reports `recoveredFromBackup`,
///      3. otherwise enters `loadDidFail` and **refuses to `save()`** — so a transient read problem can't
///         cascade into an autosave overwriting the file with `[]` — until the user explicitly resolves it.
///  * Every successful `save()` first rotates the previous good file into `songs.bak.json`, so there is
///    always a one-generation-old good copy to fall back to.
final class SongStore: ObservableObject {

    @Published private(set) var songs: [Song] = []
    /// True after the most recent write failed to reach disk. The UI reads this to warn "changes not
    /// saved" instead of silently losing work. Cleared on the next successful save.
    @Published private(set) var saveDidFail = false

    /// True when the songs file is present on disk but could not be read/decoded **and** no valid backup
    /// could be restored. While set, `save()` refuses to write over the songs file (so a transient read
    /// problem can't cascade into permanent loss); the UI surfaces a recovery banner and the user must
    /// explicitly `retryLoad()` or `startFreshDiscardingCorrupt()`.
    @Published private(set) var loadDidFail = false

    /// True when the songs file was undecodable but a good `songs.bak.json` backup was found and restored
    /// automatically. Purely informational (the library is valid again); the UI shows a reassuring banner.
    @Published private(set) var recoveredFromBackup = false

    /// Where the unreadable bytes were preserved on the most recent decode failure (`songs-corrupt-…json`),
    /// so the UI can reassure the user their data still exists and, if needed, point support at it.
    @Published private(set) var lastCorruptCopyURL: URL?

    private let directory: URL
    private let fileName: String
    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// The rolling one-generation-old good copy (`songs.bak.json` for the default `songs.json`).
    private var backupURL: URL { directory.appendingPathComponent(Self.backupFileName(for: fileName)) }

    /// Whether the file currently on disk at `fileURL` is a known-good encoding we may rotate into the
    /// backup. True after a clean load (or missing file) and after every successful save; false the moment
    /// we detect corruption, so we never poison the backup by copying corrupt/stale bytes into it.
    private var mainFileTrusted = false

    /// - Parameters:
    ///   - directory: where `songs.json` lives. Defaults to the app's Documents directory.
    ///   - fileName: overridable for tests.
    init(directory: URL? = nil, fileName: String = "songs.json") {
        self.directory = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileName = fileName
        load()
    }

    /// Replaces the in-memory list with what is on disk, distinguishing the three cases that matter for data
    /// safety: a missing file (a clean empty library), a good file (loaded), and a present-but-undecodable
    /// file (an error state that preserves the bytes and refuses to overwrite them). See the type's
    /// data-safety contract.
    func load() {
        let fm = FileManager.default

        // 1) Genuinely missing file → the normal first-run state: a clean, empty, *savable* library.
        guard fm.fileExists(atPath: fileURL.path) else {
            songs = []
            loadDidFail = false
            recoveredFromBackup = false
            mainFileTrusted = true          // nothing on disk to protect; a first save may proceed
            return
        }

        // 2) File present. Try to read + decode it. Success is the common path.
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Song].self, from: data) {
            songs = decoded
            loadDidFail = false
            recoveredFromBackup = false
            mainFileTrusted = true
            return
        }

        // 3) Present but unreadable/undecodable → NEVER treat as an empty library. Preserve the bytes and
        //    try to auto-recover from the backup; otherwise enter the refuse-to-overwrite failure state.
        enterFailureState(corruptBytes: try? Data(contentsOf: fileURL))
    }

    /// Handles a present-but-unreadable songs file: preserve the bytes, attempt backup recovery, and either
    /// restore (informational) or block saving (hard failure) — never silently empty-and-savable.
    private func enterFailureState(corruptBytes: Data?) {
        mainFileTrusted = false     // the on-disk main file is corrupt/stale — do not rotate it into backup

        // Never destroy the bytes: copy the unreadable file aside BEFORE anything else, so the user's data
        // is recoverable even if every later step fails. (Idempotent across retries — see preserveCorrupt.)
        if let corruptBytes { lastCorruptCopyURL = preserveCorrupt(corruptBytes) }

        // Rolling backup: if a previous good file was retained, recover from it automatically.
        if let backup = try? Data(contentsOf: backupURL),
           let decoded = try? JSONDecoder().decode([Song].self, from: backup) {
            songs = decoded
            recoveredFromBackup = true
            loadDidFail = false          // we have the user's data back → saving is safe again
            healMainFile()               // rewrite the good data over the corrupt main so a relaunch is clean
            return
        }

        // No valid backup: keep an empty in-memory list but BLOCK saves and demand explicit user action,
        // so a transient problem can't overwrite the original. The corrupt copy above is the recovery path.
        songs = []
        recoveredFromBackup = false
        loadDidFail = true
    }

    /// Writes the current list to disk atomically and synchronously. Creates the directory if needed and
    /// first rotates the previous good file into the backup. Returns whether the write reached disk and
    /// records failure in `saveDidFail` so a silent loss can't happen — the UI surfaces it.
    ///
    /// **Refuses to write while `loadDidFail`** (a present-but-undecodable file with no valid backup): a
    /// blocked save returns `false` and leaves the original bytes on disk untouched, so a read problem can
    /// never cascade into overwriting the file with `[]`. `@discardableResult` so existing call sites are
    /// unaffected.
    @discardableResult
    func save() -> Bool {
        guard !loadDidFail else { return false }    // recovery state: never overwrite the original
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateBackupIfTrusted()                 // retain the previous good file before overwriting it
            let data = try JSONEncoder().encode(songs)
            try data.write(to: fileURL, options: .atomic)
            mainFileTrusted = true
            if saveDidFail { saveDidFail = false }
            return true
        } catch {
            saveDidFail = true
            return false
        }
    }

    // MARK: - Recovery actions (invoked by the UI's recovery banner)

    /// "Try again": re-read from disk. Handles a *transient* read error clearing on its own (e.g. the file
    /// was briefly locked) — if the file now decodes, `loadDidFail` clears and the real library appears.
    func retryLoad() { load() }

    /// "Start fresh": accept an empty library. The unreadable data remains in the `songs-corrupt-…json`
    /// copy (and any `songs.bak.json`), so this is **non-destructive** — it just lets the user move on. Clears
    /// the block and writes a clean empty file (without rotating the corrupt main into the backup).
    func startFreshDiscardingCorrupt() {
        songs = []
        loadDidFail = false
        recoveredFromBackup = false
        mainFileTrusted = false     // on-disk main is still the corrupt file; skip backup rotation on save
        save()                      // persist the fresh empty library (corrupt original already copied aside)
    }

    /// Dismisses the "restored from backup" banner once the user has seen it.
    func acknowledgeRecovery() { recoveredFromBackup = false }

    // MARK: - Mutations (persist through the safe `save()` path above)

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

    // MARK: - Backup / corrupt-copy plumbing

    /// Retains the current on-disk file as the rolling backup before a save overwrites it — but ONLY when
    /// that file is trusted good, so corrupt or stale bytes never poison the safety net.
    private func rotateBackupIfTrusted() {
        let fm = FileManager.default
        guard mainFileTrusted, fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.removeItem(at: backupURL)
        try? fm.copyItem(at: fileURL, to: backupURL)
    }

    /// Overwrites the corrupt/stale main file with the (recovered) in-memory songs so the next launch is
    /// clean, WITHOUT rotating the corrupt main into the backup (the backup we just restored from is good —
    /// keep it). Best-effort: if the write fails the backup + corrupt-copy still keep the data safe.
    private func healMainFile() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            mainFileTrusted = true
        } catch {
            // Leave mainFileTrusted false; the corrupt copy and good backup remain the recovery path.
        }
    }

    /// Copies the unreadable bytes to a timestamped `…-corrupt-<ISO8601>.json` sidecar, returning its URL.
    /// Idempotent within a session: if we already preserved these exact bytes (e.g. the user tapped "Try
    /// again" and the file is still corrupt), reuse that copy instead of spawning duplicates.
    private func preserveCorrupt(_ data: Data) -> URL? {
        if let existing = lastCorruptCopyURL,
           let prev = try? Data(contentsOf: existing), prev == data {
            return existing
        }
        let url = uniqueCorruptCopyURL()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A collision-free destination for the corrupt copy: `<base>-corrupt-<ISO8601>.<ext>`, disambiguated
    /// with a short suffix if two corruptions land in the same second, so an earlier copy is never clobbered.
    private func uniqueCorruptCopyURL() -> URL {
        let stamp = Self.fileSafeTimestamp()
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        func make(_ tag: String) -> URL {
            let name = ext.isEmpty ? "\(fileName)-corrupt-\(stamp)\(tag)"
                                   : "\(base)-corrupt-\(stamp)\(tag).\(ext)"
            return directory.appendingPathComponent(name)
        }
        var url = make("")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("-\(n)")
            n += 1
        }
        return url
    }

    /// `songs.json` → `songs.bak.json`; a no-extension name → `<name>.bak`.
    private static func backupFileName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? "\(fileName).bak" : "\(base).bak.\(ext)"
    }

    /// An ISO8601 timestamp made filesystem-safe (colons — illegal/awkward on many filesystems — become
    /// hyphens), e.g. `2026-09-05T19-12-47Z`.
    private static func fileSafeTimestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
