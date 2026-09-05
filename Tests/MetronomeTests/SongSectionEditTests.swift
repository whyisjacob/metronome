import XCTest
import Foundation
@testable import Metronome

/// P2.6: an uncommitted edit inside an open section-editor modal must survive a force-quit. The editor now
/// commits every change to the song **live** (the builder autosaves each one via `replacingSection`), so a
/// kill mid-edit keeps the in-progress work instead of reverting the section to its just-added defaults —
/// while Cancel still restores the pre-edit snapshot.
final class SongSectionEditTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SongSectionEdit-\(UUID().uuidString)", isDirectory: true)
    }

    func testReplacingSectionReplacesByIDAndIgnoresUnknown() {
        let a = SongSection(name: "A", tempoBPM: 100)
        let b = SongSection(name: "B", tempoBPM: 90)
        let song = Song(name: "S", sections: [a, b])

        var editedA = a
        editedA.tempoBPM = 155
        let updated = song.replacingSection(editedA)
        XCTAssertEqual(updated.sections[0].tempoBPM, 155)
        XCTAssertEqual(updated.sections[1], b)                        // untouched

        // A section whose id isn't present is a no-op.
        let stranger = SongSection(name: "Z")
        XCTAssertEqual(song.replacingSection(stranger), song)
    }

    /// The force-quit scenario: after the builder adds a section and the user edits it in the modal, each
    /// change is committed live (autosaved). A fresh store — standing in for a relaunch after a kill BEFORE
    /// any explicit "Done" — must see the edited section, not the just-added defaults.
    func testInProgressSectionEditSurvivesForceQuit() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)

        // Builder "Add section": append a defaults section and autosave it.
        let added = SongSection(name: "Section 1")            // 120 BPM, 4/4, straight — the defaults
        var song = Song(name: "New Song", sections: [added])
        store.upsert(song)

        // Editor opens; the user changes tempo and name. Each change commits live to the song, which the
        // builder's `.onChange(of: song)` autosaves — modelled here by replacingSection + upsert.
        var working = added
        working.tempoBPM = 168
        working.name = "Intro"
        song = song.replacingSection(working)
        store.upsert(song)                                    // autosave of the in-progress edit

        // Force-quit here (no "Done" tapped). A relaunch reads exactly the in-progress edit.
        let reloaded = SongStore(directory: dir)
        XCTAssertEqual(reloaded.songs.count, 1)
        let section = reloaded.songs.first?.sections.first
        XCTAssertEqual(section?.tempoBPM, 168)
        XCTAssertEqual(section?.name, "Intro")
    }

    /// Cancel semantics: after live-committed edits, tapping Cancel restores the pre-edit snapshot.
    func testCancelRestoresPreEditSnapshot() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        let original = SongSection(name: "Chorus", tempoBPM: 128)
        var song = Song(name: "Tune", sections: [original])
        store.upsert(song)

        // Live edits flow into the song (and to disk)...
        var working = original
        working.tempoBPM = 200
        working.name = "Chorus (loud)"
        song = song.replacingSection(working)
        store.upsert(song)
        XCTAssertEqual(SongStore(directory: dir).songs.first?.sections.first?.tempoBPM, 200)

        // ...then Cancel restores the snapshot the builder captured when the editor opened.
        song = song.replacingSection(original)
        store.upsert(song)

        let reloaded = SongStore(directory: dir)
        XCTAssertEqual(reloaded.songs.first?.sections.first, original)
        XCTAssertEqual(reloaded.songs.first?.sections.first?.tempoBPM, 128)
        XCTAssertEqual(reloaded.songs.first?.sections.first?.name, "Chorus")
    }
}
