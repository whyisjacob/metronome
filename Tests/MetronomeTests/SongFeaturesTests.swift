import XCTest
import Foundation
@testable import Metronome

/// Tests for the song feature batch: persistence safety (P1.1), export/import (P1.2), no-section-limit
/// (P2.7), the section-seek target (P2.3), and the non-destructive master tempo scale (P3.8). Timing
/// expectations are hand-derived from first principles, never read back from `SongPlan`.
final class SongFeaturesTests: XCTestCase {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SongFeatures-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }

    // MARK: - P1.1 Persistence is bulletproof

    /// A full song — sections with groove, custom accents, repeats, and a master scale — survives a
    /// save→reload in a fresh store, field-for-field (atomic + synchronous write, so it persists across
    /// termination, not just backgrounding).
    func testFullSongRoundTripsThroughStorePreservingEveryField() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let song = Song(name: "Full", sections: [
            SongSection(name: "A", tempoBPM: 137,
                        timeSignature: TimeSignature(numerator: 7, denominator: 8), subdivision: .triplet,
                        accentPattern: [.strong, .normal, .medium, .normal, .medium, .normal, .normal],
                        bars: 3, repeatCount: 2, swing: 0.4, cell: .straight),
            SongSection(name: "B", tempoBPM: 96, timeSignature: .common, subdivision: .sixteenth,
                        accentPattern: [.strong, .normal, .medium, .normal],
                        bars: 1, repeatCount: 1, swing: 0, cell: .gallop),
        ], tempoScale: 0.9)

        SongStore(directory: dir).upsert(song)
        let reloaded = SongStore(directory: dir)
        XCTAssertEqual(reloaded.songs, [song], "every field must survive save→reload")

        // Spot-check the fields most likely to be dropped.
        let a = reloaded.songs[0].sections[0]
        XCTAssertEqual(a.swing, 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.repeatCount, 2)
        XCTAssertEqual(a.accentPattern.count, 7)
        XCTAssertEqual(reloaded.songs[0].sections[1].cell, .gallop)
        XCTAssertEqual(reloaded.songs[0].tempoScale, 0.9, accuracy: 1e-9)
    }

    /// A failed write is SURFACED, not swallowed: pointing the store at a directory that can't be created
    /// (a child of a regular file) flips `saveDidFail`.
    func testSaveFailureIsSurfacedNotSilent() throws {
        let fileURL = makeTempDir().deletingLastPathComponent()
            .appendingPathComponent("not-a-dir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // A directory *under a regular file* can never be created, so createDirectory/write must fail.
        let store = SongStore(directory: fileURL.appendingPathComponent("child"))
        store.upsert(Song(name: "X"))
        XCTAssertTrue(store.saveDidFail, "a failed write must be surfaced, not silently lost")
    }

    // MARK: - P1.2 Export / import / share

    func testSongTransferEncodeDecodeRoundTripsAndReidentifies() throws {
        let song = Song(name: "Share Me",
                        sections: [SongSection(name: "A", tempoBPM: 120, swing: 0.5, cell: .gallop)],
                        tempoScale: 1.1)
        let decoded = try SongTransfer.decode(try SongTransfer.encode(song))

        XCTAssertEqual(decoded.name, song.name)
        XCTAssertEqual(decoded.sections.count, 1)
        XCTAssertEqual(decoded.sections[0].tempoBPM, 120)
        XCTAssertEqual(decoded.sections[0].swing, 0.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.sections[0].cell, .gallop)
        XCTAssertEqual(decoded.tempoScale, 1.1, accuracy: 1e-9)
        // Imported as a NEW entry — fresh identity so it never overwrites an existing song.
        XCTAssertNotEqual(decoded.id, song.id)
        XCTAssertNotEqual(decoded.sections[0].id, song.sections[0].id)
    }

    func testSongTransferIsVersionedAndDegradesGracefully() throws {
        let song = Song(name: "V", sections: [SongSection(name: "A")])

        // The exported document carries a version field.
        let wrapped = try SongTransfer.encode(song)
        XCTAssertTrue(String(data: wrapped, encoding: .utf8)!.contains("\"version\""))

        // A bare Song JSON (no wrapper) still imports.
        let fromBare = try SongTransfer.decode(try JSONEncoder().encode(song))
        XCTAssertEqual(fromBare.name, "V")

        // A future document (higher version, unknown extra field, missing optional fields) imports what it
        // can and defaults the rest — never rejects.
        let future = """
        {"version": 99, "song": {"name": "Future", "futuristicTop": 1,
          "sections": [{"name": "X", "tempoBPM": 150, "futuristicField": true}]}}
        """.data(using: .utf8)!
        let fromFuture = try SongTransfer.decode(future)
        XCTAssertEqual(fromFuture.name, "Future")
        XCTAssertEqual(fromFuture.sections.count, 1)
        XCTAssertEqual(fromFuture.sections[0].tempoBPM, 150)
        XCTAssertEqual(fromFuture.sections[0].timeSignature, .common, "missing meter → 4/4 default")
        XCTAssertEqual(fromFuture.sections[0].swing, 0, accuracy: 1e-9, "missing groove → straight")
    }

    // MARK: - P2.7 No section limit

    func testLargeSectionCountRoundTripsAndExpands() {
        let sections = (0..<60).map { i in
            SongSection(name: "S\(i)", tempoBPM: 100 + Double(i % 40),
                        timeSignature: .common, subdivision: .quarter, bars: 2)
        }
        let song = Song(name: "Long", sections: sections)
        XCTAssertEqual(song.sections.count, 60)
        XCTAssertEqual(song.totalBars, 120)               // 60 sections × 2 bars

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        SongStore(directory: dir).upsert(song)
        XCTAssertEqual(SongStore(directory: dir).songs.first?.sections.count, 60,
                       "a 60-section song must persist with no cap")

        let plan = SongPlan(song: song, sampleRate: 44_100)
        XCTAssertEqual(plan.sectionCount, 60)
        XCTAssertEqual(plan.clickCount, 60 * 2 * 4)        // 60 sections × 2 bars × 4 quarter clicks
    }

    // MARK: - P2.3 Section-seek target (first principles)

    func testSongPlanFirstClickIndexOfSection() {
        // A: 4/4 quarter × 1 bar = 4 clicks; B: 3/4 quarter × 2 bars = 6; C: 4/4 eighth × 1 bar = 8.
        let song = Song(name: "Seek", sections: [
            SongSection(name: "A", timeSignature: .common, subdivision: .quarter, bars: 1),
            SongSection(name: "B", timeSignature: TimeSignature(numerator: 3, denominator: 4),
                        subdivision: .quarter, bars: 2),
            SongSection(name: "C", timeSignature: .common, subdivision: .eighth, bars: 1),
        ])
        let plan = SongPlan(song: song, sampleRate: 44_100)
        XCTAssertEqual(plan.sectionCount, 3)
        XCTAssertEqual(plan.firstClickIndex(ofSection: 0), 0)     // hand-derived cumulative click counts
        XCTAssertEqual(plan.firstClickIndex(ofSection: 1), 4)
        XCTAssertEqual(plan.firstClickIndex(ofSection: 2), 10)    // 4 + 6
        XCTAssertEqual(plan.firstClickIndex(ofSection: 3), 18)    // 4 + 6 + 8 == clickCount (clamp-safe end)
        XCTAssertEqual(plan.clickCount, 18)
    }

    // MARK: - P3.8 Master tempo scale (non-destructive)

    func testMasterTempoScaleIsProportionalNonDestructiveAndResettable() {
        var song = Song(name: "Scale", sections: [
            SongSection(name: "Verse", tempoBPM: 120),
            SongSection(name: "Bridge", tempoBPM: 90),   // Bridge is 75% of Verse — a ratio to preserve
        ])

        // 100%: resulting == original.
        XCTAssertEqual(song.resultingBPM(120), 120)
        XCTAssertEqual(song.resultingBPM(90), 90)

        // 95% (first principles): 120×0.95 = 114; 90×0.95 = 85.5 → 86.
        song.tempoScale = 0.95
        XCTAssertEqual(song.resultingBPM(120), 114)
        XCTAssertEqual(song.resultingBPM(90), 86)

        // The Verse:Bridge ratio is preserved (why % beats a flat ±BPM offset).
        XCTAssertEqual(Double(song.resultingBPM(90)) / Double(song.resultingBPM(120)),
                       90.0 / 120.0, accuracy: 0.02)

        // playbackScaled flattens the scale into section BPMs; the ORIGINAL sections stay untouched.
        let play = song.playbackScaled()
        XCTAssertEqual(play.sections[0].tempoBPM, 114)
        XCTAssertEqual(play.sections[1].tempoBPM, 86)
        XCTAssertEqual(play.tempoScale, 1.0)
        XCTAssertEqual(song.sections[0].tempoBPM, 120, "original section BPMs must NOT be rewritten")
        XCTAssertEqual(song.sections[1].tempoBPM, 90)

        // Reset restores exactly.
        song.tempoScale = 1.0
        XCTAssertEqual(song.playbackScaled().sections[0].tempoBPM, 120)
        XCTAssertEqual(song.playbackScaled().sections[1].tempoBPM, 90)
    }

    @MainActor
    func testMasterTempoScaleUpdatesTheSharedViewModelAndPersists() {
        let vm = MetronomeViewModel()
        var persisted: Song?
        vm.onSongEdited = { persisted = $0 }

        let song = Song(name: "S", sections: [
            SongSection(name: "A", tempoBPM: 120), SongSection(name: "B", tempoBPM: 90),
        ])
        vm.playSong(song)
        vm.pauseSong()                 // stop audio so setTempoScale takes the no-rebuild path

        vm.setTempoScale(0.9)
        XCTAssertEqual(vm.tempoScale, 0.9, accuracy: 1e-9)
        XCTAssertEqual(vm.activeSong?.tempoScale ?? -1, 0.9, accuracy: 1e-9)
        XCTAssertEqual(persisted?.tempoScale ?? -1, 0.9, accuracy: 1e-9, "scale change persisted via onSongEdited")
        XCTAssertEqual(vm.activeSong?.sections[0].tempoBPM, 120, "the original section BPM is untouched")

        vm.resetTempoScale()
        XCTAssertEqual(vm.tempoScale, 1.0, accuracy: 1e-9)
    }
}
