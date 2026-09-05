import XCTest
@testable import Metronome

/// First-principles proof that a section's groove (swing / cell) expands correctly in `SongPlan`, and —
/// crucially — that a straight section is byte-for-byte unchanged by the added groove support (so every
/// existing song accuracy test still holds). Expectations are hand-computed from the musical definition,
/// never read from `SongPlan`.
final class SongGrooveSectionTests: XCTestCase {

    private let sr = 48_000.0

    private func plan(_ section: SongSection) -> SongPlan {
        SongPlan(song: Song(name: "T", sections: [section]), sampleRate: sr)
    }

    /// A straight section places clicks at exactly `i × framesPerTick`, unaffected by the groove support
    /// (swing 0, cell off). 4/4 eighth @120 @48kHz → 12000 frames/tick.
    func testStraightSectionIsUnchanged() {
        let s = SongSection(name: "Straight", tempoBPM: 120, timeSignature: .common,
                            subdivision: .eighth, bars: 1)   // swing 0, cell .straight by default
        let p = plan(s)
        XCTAssertEqual(p.clickCount, 8)
        for i in 0..<8 { XCTAssertEqual(p.frame(at: i), i * 12_000, "straight eighth tick \(i)") }
    }

    /// A fully-swung section moves the off-eighths to ⅔ of the beat while the on-beats stay put — the same
    /// `SwingGrid` math the single-tempo path uses. 4/4 eighth @120 @48kHz: beat 24000, off-eighth 16000.
    func testSwungSectionMovesOffEighthsToTwoThirds() {
        let s = SongSection(name: "Swing", tempoBPM: 120, timeSignature: .common,
                            subdivision: .eighth, bars: 1, swing: 1.0)
        let p = plan(s)
        XCTAssertEqual(p.frame(at: 0), 0)          // beat 1 — on the grid
        XCTAssertEqual(p.frame(at: 1), 16_000)     // off-eighth → ⅔ of the beat (24000 × 2/3)
        XCTAssertEqual(p.frame(at: 2), 24_000)     // beat 2 — never moves
        XCTAssertEqual(p.frame(at: 3), 40_000)     // 24000 + 16000
        // Section length (and thus any following boundary) is unaffected by swing: on-beats don't move, so
        // the whole bar is still 8 × 12000.
        XCTAssertEqual(p.totalFrames, 96_000)
    }

    /// A section with an idiomatic cell silences the cell's off-positions on the sixteenth grid, exactly
    /// like the single-tempo `RhythmCell`. Dotted-8th+16th = [0, 3]: positions 1 and 2 are muted.
    func testCelledSectionSilencesTheCellOffPositions() {
        let s = SongSection(name: "Cell", tempoBPM: 120, timeSignature: .common,
                            subdivision: .sixteenth, bars: 1, cell: .dottedEighthSixteenth)
        let p = plan(s)
        // Beat 1 (positions 0…3): downbeat sounds, 1 & 2 muted, 3 sounds (weak).
        XCTAssertEqual(p.accent(at: 0), .strong)
        XCTAssertEqual(p.accent(at: 1), .muted)
        XCTAssertEqual(p.accent(at: 2), .muted)
        XCTAssertEqual(p.accent(at: 3), .weak)
        // Timing is untouched by the cell — the muted slots keep their exact grid frames (6000/tick @48k).
        for i in 0..<4 { XCTAssertEqual(p.frame(at: i), i * 6_000, "celled sixteenth tick \(i)") }
    }

    /// `SongSection(from:)` and Codable carry the groove, so a saved song reproduces the feel.
    func testGrooveSurvivesFromConfigAndCodable() throws {
        let config = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .sixteenth,
                                            swing: 0.7, cell: .gallop)
        let section = SongSection(from: config)
        XCTAssertEqual(section.swing, 0.7, accuracy: 1e-9)
        XCTAssertEqual(section.cell, .gallop)

        let decoded = try JSONDecoder().decode(SongSection.self, from: JSONEncoder().encode(section))
        XCTAssertEqual(decoded.swing, 0.7, accuracy: 1e-9)
        XCTAssertEqual(decoded.cell, .gallop)
        XCTAssertEqual(decoded, section)
    }
}
