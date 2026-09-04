import XCTest
import Foundation
@testable import Metronome

/// The "Save as Song" building blocks: turning a live `MetronomeConfiguration` into a one-section `Song`
/// must preserve tempo, meter, subdivision and accents exactly, and the result must round-trip the store.
final class SongFromSettingsTests: XCTestCase {

    func testSectionFromConfigMirrorsEverySetting() {
        let config = MetronomeConfiguration(
            bpm: 132,
            timeSignature: TimeSignature(numerator: 7, denominator: 8),
            subdivision: .triplet,
            accents: [true, false, false, true, false, false, false],
            sound: .woodblock)

        let section = SongSection(from: config)
        XCTAssertEqual(section.tempoBPM, 132)
        XCTAssertEqual(section.timeSignature, TimeSignature(numerator: 7, denominator: 8))
        XCTAssertEqual(section.subdivision, .triplet)
        XCTAssertEqual(section.accentPattern, [true, false, false, true, false, false, false])
        XCTAssertEqual(section.bars, 1)
        XCTAssertEqual(section.repeatCount, 1)
    }

    func testSongFromCurrentSettingsHasOneMatchingSection() {
        let config = MetronomeConfiguration(bpm: 100, timeSignature: .common, subdivision: .eighth)
        let song = Song(fromCurrentSettings: config)

        XCTAssertEqual(song.name, "New Song")
        XCTAssertEqual(song.sections.count, 1)
        let s = song.sections[0]
        XCTAssertEqual(s.tempoBPM, 100)
        XCTAssertEqual(s.timeSignature, .common)
        XCTAssertEqual(s.subdivision, .eighth)
        XCTAssertEqual(s.accentPattern, config.accents)   // default accents carried through
    }

    func testCustomSongName() {
        let song = Song(fromCurrentSettings: MetronomeConfiguration(), name: "My Piece")
        XCTAssertEqual(song.name, "My Piece")
    }

    /// A clamped config (out-of-range BPM) must still yield a valid section with the clamped value.
    func testClampedConfigProducesValidSection() {
        let config = MetronomeConfiguration(bpm: 999)
        XCTAssertEqual(config.bpm, 300)
        XCTAssertEqual(SongSection(from: config).tempoBPM, 300)
    }

    func testSaveAsSongRoundTripsThroughStore() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongFromSettings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SongStore(directory: dir)
        let config = MetronomeConfiguration(bpm: 145,
                                            timeSignature: TimeSignature(numerator: 5, denominator: 4),
                                            subdivision: .sixteenth)
        store.upsert(Song(fromCurrentSettings: config, name: "From Current"))

        let reloaded = SongStore(directory: dir)
        XCTAssertEqual(reloaded.songs.count, 1)
        let first = reloaded.songs.first?.sections.first
        XCTAssertEqual(first?.tempoBPM, 145)
        XCTAssertEqual(first?.timeSignature.numerator, 5)
        XCTAssertEqual(first?.subdivision, .sixteenth)
    }
}
