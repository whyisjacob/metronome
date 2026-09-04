import XCTest
import Foundation
@testable import Metronome

/// Validation of the `Song` / `SongSection` value types and round-trip persistence through `SongStore`.
final class SongPersistenceTests: XCTestCase {

    // MARK: - Validation / clamping

    func testTempoClampedToSupportedRange() {
        XCTAssertEqual(SongSection(tempoBPM: 5).tempoBPM, 30)
        XCTAssertEqual(SongSection(tempoBPM: 9000).tempoBPM, 300)
        XCTAssertEqual(SongSection(tempoBPM: 137).tempoBPM, 137)
    }

    func testBarsAndRepeatFlooredAtOne() {
        let s = SongSection(bars: 0, repeatCount: 0)
        XCTAssertEqual(s.bars, 1)
        XCTAssertEqual(s.repeatCount, 1)
        XCTAssertEqual(SongSection(bars: -4, repeatCount: -1).bars, 1)
    }

    func testAccentPatternNormalizedToNumerator() {
        // Too few → padded; downbeat defaulted when all-off.
        let s = SongSection(timeSignature: TimeSignature(numerator: 5, denominator: 4),
                            accentPattern: [false, false])
        XCTAssertEqual(s.accentPattern.count, 5)
        XCTAssertEqual(s.accentPattern, [true, false, false, false, false])

        // Too many → truncated.
        let t = SongSection(timeSignature: TimeSignature(numerator: 2, denominator: 4),
                            accentPattern: [true, false, true, true])
        XCTAssertEqual(t.accentPattern, [true, false])
    }

    func testDerivedTimingMatchesFirstPrinciples() {
        // 90 BPM, 3/4, eighth, 2 bars ×2 repeats.
        let s = SongSection(tempoBPM: 90,
                            timeSignature: TimeSignature(numerator: 3, denominator: 4),
                            subdivision: .eighth, bars: 2, repeatCount: 2)
        XCTAssertEqual(s.ticksPerBeat, 2)
        XCTAssertEqual(s.ticksPerBar, 6)              // 2 ticks/beat × 3 beats
        XCTAssertEqual(s.totalBars, 4)                // 2 × 2
        XCTAssertEqual(s.totalTicks, 24)              // 6 × 4
        XCTAssertEqual(s.secondsPerBeat, 60.0 / 90.0, accuracy: 1e-12)
        XCTAssertEqual(s.secondsPerTick, (60.0 / 90.0) / 2.0, accuracy: 1e-12)
        XCTAssertEqual(s.framesPerTick(sampleRate: 48_000), (60.0 / 90.0) / 2.0 * 48_000, accuracy: 1e-9)
    }

    // MARK: - Codable round-trips

    func testSectionCodableRoundTrip() throws {
        let original = SongSection(name: "Chorus", tempoBPM: 128,
                                   timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                   subdivision: .triplet, accentPattern: [true, false, false, true, false, false],
                                   bars: 4, repeatCount: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SongSection.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSongCodableRoundTrip() throws {
        let song = Song(name: "Etude", sections: [
            SongSection(name: "A", tempoBPM: 120),
            SongSection(name: "B", tempoBPM: 90, timeSignature: TimeSignature(numerator: 3, denominator: 4),
                        subdivision: .eighth, bars: 2, repeatCount: 2),
        ])
        let data = try JSONEncoder().encode(song)
        let decoded = try JSONDecoder().decode(Song.self, from: data)
        XCTAssertEqual(decoded, song)
    }

    /// A hand-written JSON with an out-of-range tempo and a zero bar count must load clamped, not raw —
    /// decoding goes through the validating initializer.
    func testDecodingClampsHostileValues() throws {
        let json = """
        { "id": "3E1E1B7E-0000-0000-0000-000000000001", "name": "Bad",
          "tempoBPM": 9999, "timeSignature": { "numerator": 4, "denominator": 4 },
          "subdivision": "quarter", "accentPattern": [false, false, false, false],
          "bars": 0, "repeatCount": 0 }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(SongSection.self, from: json)
        XCTAssertEqual(s.tempoBPM, 300)
        XCTAssertEqual(s.bars, 1)
        XCTAssertEqual(s.repeatCount, 1)
        XCTAssertEqual(s.accentPattern, [true, false, false, false])   // all-off → downbeat forced
    }

    // MARK: - SongStore persistence

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongStoreTests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    func testSaveThenLoadInFreshStoreEquals() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        XCTAssertTrue(store.songs.isEmpty)

        let a = Song(name: "One", sections: [SongSection(name: "A", tempoBPM: 100)])
        let b = Song(name: "Two", sections: [
            SongSection(name: "A", tempoBPM: 120),
            SongSection(name: "B", tempoBPM: 90, timeSignature: TimeSignature(numerator: 7, denominator: 8),
                        subdivision: .triplet, bars: 3),
        ])
        store.upsert(a)
        store.upsert(b)

        // A brand-new store reading the same directory sees exactly what was saved.
        let reloaded = SongStore(directory: dir)
        XCTAssertEqual(reloaded.songs, [a, b])
    }

    func testUpsertReplacesByID() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        var song = Song(name: "Draft", sections: [SongSection(name: "A")])
        store.upsert(song)
        song.name = "Final"
        store.upsert(song)

        XCTAssertEqual(store.songs.count, 1)
        XCTAssertEqual(store.songs.first?.name, "Final")
        XCTAssertEqual(SongStore(directory: dir).songs.first?.name, "Final")
    }

    func testDeleteAndMovePersist() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        let a = Song(name: "A"); let b = Song(name: "B"); let c = Song(name: "C")
        store.upsert(a); store.upsert(b); store.upsert(c)

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)   // A → end: [B, C, A]
        XCTAssertEqual(store.songs.map(\.name), ["B", "C", "A"])

        store.delete(c)
        XCTAssertEqual(store.songs.map(\.name), ["B", "A"])
        XCTAssertEqual(SongStore(directory: dir).songs.map(\.name), ["B", "A"])
    }

    func testLoadFromMissingFileIsEmpty() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(SongStore(directory: dir).songs.isEmpty)
    }
}
