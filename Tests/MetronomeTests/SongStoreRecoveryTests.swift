import XCTest
import Foundation
@testable import Metronome

/// P1 data-safety: a present-but-undecodable songs file must NEVER be silently mapped to an empty,
/// savable library (which the builder's autosave would then overwrite the file with, destroying a
/// hand-entered song permanently). These are behavioral tests: they write real corrupt/garbage bytes to
/// the store's actual on-disk location and assert the store preserves the bytes, refuses to overwrite the
/// original, auto-recovers from the rolling backup, and only ever empties on a genuinely missing file.
final class SongStoreRecoveryTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SongStoreRecovery-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ data: Data, to dir: URL, named name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// The `songs-corrupt-<ISO8601>.json` sidecars the store keeps when it can't read the main file.
    private func corruptCopies(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("songs-corrupt-") }
    }

    private func garbage(_ s: String = "<<< this is definitely not a songs array >>>") -> Data {
        Data(s.utf8)
    }

    // MARK: (a) A corrupt file is NOT a silently-empty, savable library

    func testCorruptFileIsNotSilentlyEmptyAndSavable() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(garbage(), to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.songs.isEmpty)            // no data to show...
        XCTAssertTrue(store.loadDidFail)              // ...but this is an ERROR state, not an empty library
        XCTAssertFalse(store.recoveredFromBackup)
        XCTAssertFalse(store.save())                  // and saving is REFUSED while blocked
    }

    // MARK: (b) The unreadable bytes are copied aside

    func testCorruptCopyIsCreated() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = garbage("corrupt-me")
        try write(bytes, to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        let copies = corruptCopies(in: dir)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), bytes)      // exact bytes preserved
        XCTAssertEqual(store.lastCorruptCopyURL, copies[0])
    }

    // MARK: (c) A save in the failure state does NOT overwrite the original

    func testSaveDoesNotOverwriteOriginalWhileInFailureState() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = garbage("precious but unreadable")
        try write(original, to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.loadDidFail)

        XCTAssertFalse(store.save())
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("songs.json")), original)

        // Even an upsert (which calls save) cannot clobber the file while blocked.
        store.upsert(Song(name: "Should not reach disk"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("songs.json")), original)
    }

    // MARK: (d) A valid backup is auto-restored

    func testValidBackupIsAutoRestored() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = [Song(name: "Backed up", sections: [SongSection(name: "A", tempoBPM: 111)])]
        try write(try JSONEncoder().encode(good), to: dir, named: "songs.bak.json")
        try write(garbage(), to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertFalse(store.loadDidFail)             // recovered, not blocked
        XCTAssertTrue(store.recoveredFromBackup)
        XCTAssertEqual(store.songs, good)             // the user's data is back
        XCTAssertFalse(corruptCopies(in: dir).isEmpty)  // and the bad bytes were still preserved
    }

    // MARK: (e) A genuinely missing file yields a clean, empty, savable library

    func testMissingFileIsCleanEmptyAndSavable() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.songs.isEmpty)
        XCTAssertFalse(store.loadDidFail)
        XCTAssertFalse(store.recoveredFromBackup)
        XCTAssertTrue(store.save())                   // a first save is allowed

        store.upsert(Song(name: "First"))
        XCTAssertEqual(SongStore(directory: dir).songs.map(\.name), ["First"])
        XCTAssertTrue(corruptCopies(in: dir).isEmpty) // nothing was ever treated as corrupt
    }

    // MARK: Full save → corrupt → recover round-trip

    func testFullSaveCorruptRecoverRoundTrip() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        let a = Song(name: "Keeper", sections: [SongSection(name: "A", tempoBPM: 118)])
        store.upsert(a)                               // main = [a]
        let b = Song(name: "Second", sections: [SongSection(name: "B", tempoBPM: 96)])
        store.upsert(b)                               // main = [a, b]; backup rotated to previous good = [a]

        // Corrupt the main file on disk (truncation / bad flush / external tampering).
        try garbage("half-written file").write(to: dir.appendingPathComponent("songs.json"))

        // A fresh store recovers from the backup instead of showing an empty (soon-to-be-overwritten) library.
        let recovered = SongStore(directory: dir)
        XCTAssertFalse(recovered.loadDidFail)
        XCTAssertTrue(recovered.recoveredFromBackup)
        XCTAssertEqual(recovered.songs, [a])          // the one-generation-old good copy
        XCTAssertFalse(corruptCopies(in: dir).isEmpty)

        // The main file was healed, so the NEXT launch is clean — no failure and no repeat recovery.
        let relaunched = SongStore(directory: dir)
        XCTAssertFalse(relaunched.loadDidFail)
        XCTAssertFalse(relaunched.recoveredFromBackup)
        XCTAssertEqual(relaunched.songs, [a])

        // And it is fully savable again.
        relaunched.upsert(Song(name: "Third"))
        XCTAssertEqual(SongStore(directory: dir).songs.map(\.name), ["Keeper", "Third"])
    }

    // MARK: "Start fresh" is non-destructive; "Try again" recovers a transient failure

    func testStartFreshDiscardsCorruptNonDestructively() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = garbage("keep me around")
        try write(original, to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.loadDidFail)
        let copies = corruptCopies(in: dir)
        XCTAssertEqual(copies.count, 1)

        store.startFreshDiscardingCorrupt()
        XCTAssertFalse(store.loadDidFail)
        XCTAssertTrue(store.songs.isEmpty)
        XCTAssertEqual(SongStore(directory: dir).songs, [])            // main is now a clean empty library
        XCTAssertFalse(SongStore(directory: dir).loadDidFail)
        XCTAssertEqual(try Data(contentsOf: copies[0]), original)      // corrupt bytes still preserved

        store.upsert(Song(name: "Fresh"))
        XCTAssertEqual(SongStore(directory: dir).songs.map(\.name), ["Fresh"])
    }

    func testRetryLoadRecoversWhenFileBecomesValidAgain() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let songsFile = dir.appendingPathComponent("songs.json")
        try write(garbage("temporarily broken"), to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.loadDidFail)

        // The underlying problem clears out of band (e.g. a sync finished writing the real file).
        let good = [Song(name: "Recovered")]
        try JSONEncoder().encode(good).write(to: songsFile)

        store.retryLoad()
        XCTAssertFalse(store.loadDidFail)
        XCTAssertEqual(store.songs, good)
    }

    /// Retrying while the file is STILL corrupt must not spawn a second corrupt copy (idempotent).
    func testRetryWhileStillCorruptDoesNotDuplicateCopies() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(garbage("still broken"), to: dir, named: "songs.json")

        let store = SongStore(directory: dir)
        XCTAssertEqual(corruptCopies(in: dir).count, 1)
        store.retryLoad()
        store.retryLoad()
        XCTAssertEqual(corruptCopies(in: dir).count, 1)   // same bytes → same single copy
        XCTAssertTrue(store.loadDidFail)
    }
}
