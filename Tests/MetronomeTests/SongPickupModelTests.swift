import XCTest
import Foundation
@testable import Metronome

/// P3.8 / P3.9 — the pickup DATA MODEL: `SongSection.pickupTicks` (a section anacrusis, in current-grid
/// ticks) and `Song.pickupTicks` (a song-start anacrusis). This proves the value semantics — tick clamping
/// to `0 … ticksPerBar−1`, re-clamping when the section's grid shrinks — and, crucially, **backward
/// compatibility**: a song saved or exported BEFORE these fields existed still decodes correctly (the new
/// fields default to 0). It does NOT assert any audio behaviour: the section-start lead-in playback (P3.10)
/// is deferred, so nothing here reads back from the engine's `SongPlan`.
final class SongPickupModelTests: XCTestCase {

    // MARK: - SongSection.pickupTicks clamping (0 … ticksPerBar−1)

    func testSectionPickupClampedToBarInSimpleMeter() {
        // 4/4 quarter → ticksPerBar = 4, so a pickup is at most 3.
        XCTAssertEqual(SongSection(subdivision: .quarter, pickupTicks: 5).pickupTicks, 3)
        XCTAssertEqual(SongSection(subdivision: .quarter, pickupTicks: 3).pickupTicks, 3)
        XCTAssertEqual(SongSection(subdivision: .quarter, pickupTicks: 1).pickupTicks, 1)
        XCTAssertEqual(SongSection(subdivision: .quarter, pickupTicks: 0).pickupTicks, 0)
        XCTAssertEqual(SongSection(subdivision: .quarter, pickupTicks: -4).pickupTicks, 0)
    }

    func testSectionPickupOnFinerGridAllowsMoreTicks() {
        // 4/4 sixteenth → ticksPerBar = 16, so up to 15 (the classic sub-beat pickup lives here).
        XCTAssertEqual(SongSection(subdivision: .sixteenth, pickupTicks: 2).pickupTicks, 2)   // "and, a" style
        XCTAssertEqual(SongSection(subdivision: .sixteenth, pickupTicks: 16).pickupTicks, 15)
    }

    func testSectionPickupInCompoundMeter() {
        // 6/8 eighth → dotted-quarter beat, ticksPerBeat 3 × 2 beats = 6 ticks/bar → up to 5.
        let s = SongSection(timeSignature: TimeSignature(numerator: 6, denominator: 8),
                            subdivision: .eighth, pickupTicks: 9)
        XCTAssertEqual(s.ticksPerBar, 6)
        XCTAssertEqual(s.pickupTicks, 5)
    }

    func testSectionPickupImpossibleInOneTickBar() {
        // 1/4 quarter → 1 tick/bar → no room for a pickup at all.
        let s = SongSection(timeSignature: TimeSignature(numerator: 1, denominator: 4),
                            subdivision: .quarter, pickupTicks: 3)
        XCTAssertEqual(s.ticksPerBar, 1)
        XCTAssertEqual(s.pickupTicks, 0)
    }

    /// The pickup re-clamps when the section's meter/subdivision change shrinks the bar — modelled by the
    /// editor's save path (`updating(from:)`) and by a direct rebuild through the initializer.
    func testSectionPickupReclampsWhenGridShrinks() {
        // Start on a sixteenth grid with a 6-tick pickup (fits: ticksPerBar 16).
        let wide = SongSection(subdivision: .sixteenth, pickupTicks: 6)
        XCTAssertEqual(wide.pickupTicks, 6)

        // Editor changes the subdivision to quarter (ticksPerBar 4): the 6-tick pickup no longer fits.
        var narrowerConfig = wide.configuration
        narrowerConfig.subdivision = .quarter
        let reclamped = wide.updating(from: narrowerConfig, name: wide.name,
                                      bars: wide.bars, repeatCount: wide.repeatCount)
        XCTAssertEqual(reclamped.ticksPerBar, 4)
        XCTAssertEqual(reclamped.pickupTicks, 3, "a shorter bar must re-clamp a now-too-long pickup")
    }

    // MARK: - Song.pickupTicks

    func testSongPickupFlooredAtZero() {
        XCTAssertEqual(Song(pickupTicks: -3).pickupTicks, 0)
        XCTAssertEqual(Song(pickupTicks: 2).pickupTicks, 2)
    }

    // MARK: - Codable round-trips (the new fields survive save/load)

    func testSectionPickupRoundTrips() throws {
        let original = SongSection(name: "Verse", subdivision: .sixteenth, pickupTicks: 3)
        let decoded = try JSONDecoder().decode(SongSection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.pickupTicks, 3)
    }

    func testSongPickupRoundTrips() throws {
        let song = Song(name: "Etude", sections: [SongSection(name: "A", subdivision: .eighth, pickupTicks: 1)],
                        pickupTicks: 2)
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(decoded, song)
        XCTAssertEqual(decoded.pickupTicks, 2)
        XCTAssertEqual(decoded.sections.first?.pickupTicks, 1)
    }

    func testPickupSurvivesDuplicateAndScale() {
        let song = Song(name: "S", sections: [SongSection(name: "A", subdivision: .eighth, pickupTicks: 1)],
                        pickupTicks: 2)
        XCTAssertEqual(song.duplicated().pickupTicks, 2)
        XCTAssertEqual(song.duplicated().sections.first?.pickupTicks, 1)
        // Master-tempo scaling is non-destructive and preserves pickups.
        var scaledSong = song; scaledSong.tempoScale = 1.5
        let played = scaledSong.playbackScaled()
        XCTAssertEqual(played.pickupTicks, 2)
        XCTAssertEqual(played.sections.first?.pickupTicks, 1)
    }

    // MARK: - Backward compatibility: a file saved BEFORE the pickup fields still loads

    /// Simulate an old on-disk section by encoding a modern one and deleting the `pickupTicks` key, exactly
    /// as a pre-pickup build's file would lack it. It must decode with every other field intact and
    /// `pickupTicks == 0`.
    func testOldSectionJSONWithoutPickupDecodesToZero() throws {
        let modern = SongSection(name: "Chorus", tempoBPM: 132,
                                 timeSignature: TimeSignature(numerator: 7, denominator: 8),
                                 subdivision: .triplet, bars: 4, repeatCount: 2, swing: 0.3, cell: .straight,
                                 pickupTicks: 4)
        let stripped = try stripKeys(["pickupTicks"], fromObjectIn: JSONEncoder().encode(modern))
        let decoded = try JSONDecoder().decode(SongSection.self, from: stripped)
        XCTAssertEqual(decoded.pickupTicks, 0)
        XCTAssertEqual(decoded.name, "Chorus")
        XCTAssertEqual(decoded.tempoBPM, 132)
        XCTAssertEqual(decoded.timeSignature, TimeSignature(numerator: 7, denominator: 8))
        XCTAssertEqual(decoded.subdivision, .triplet)
        XCTAssertEqual(decoded.bars, 4)
        XCTAssertEqual(decoded.repeatCount, 2)
        XCTAssertEqual(decoded.swing, 0.3, accuracy: 1e-9)
    }

    /// A hand-written OLD song file (as the previous build wrote it: no pickupTicks anywhere, and — being
    /// even older — no swing/cell keys either) must load with all fields sensible and pickups 0. This is the
    /// explicit "pre-existing saved song still loads" guarantee.
    func testHandWrittenPrePickupSongLoads() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Old Song",
          "tempoScale": 1.0,
          "sections": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "A",
              "tempoBPM": 120,
              "timeSignature": { "numerator": 4, "denominator": 4 },
              "subdivision": "eighth",
              "accentPattern": ["strong", "normal", "medium", "normal"],
              "bars": 2,
              "repeatCount": 1
            }
          ]
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.name, "Old Song")
        XCTAssertEqual(song.pickupTicks, 0)
        XCTAssertEqual(song.sections.count, 1)
        let s = song.sections[0]
        XCTAssertEqual(s.name, "A")
        XCTAssertEqual(s.tempoBPM, 120)
        XCTAssertEqual(s.subdivision, .eighth)
        XCTAssertEqual(s.bars, 2)
        XCTAssertEqual(s.pickupTicks, 0)      // defaulted, not required in the old file
        XCTAssertEqual(s.swing, 0)            // pre-groove default
        XCTAssertEqual(s.cell, .straight)     // pre-cell default
    }

    /// The same guarantee through the SHARED `.maelzelsong` path: an exported file written before the pickup
    /// fields (its `pickupTicks` keys absent) still imports. Import reidentifies (fresh ids), so compare the
    /// musical fields, not identity.
    func testOldExportedSongWithoutPickupImports() throws {
        let modern = Song(name: "Shared", sections: [SongSection(name: "A", subdivision: .eighth, pickupTicks: 2)],
                          pickupTicks: 3)
        let exported = try SongTransfer.encode(modern)
        let oldExported = try strippingPickupsFromExport(exported)
        let imported = try SongTransfer.decode(oldExported)
        XCTAssertEqual(imported.name, "Shared")
        XCTAssertEqual(imported.pickupTicks, 0)
        XCTAssertEqual(imported.sections.first?.pickupTicks, 0)
        XCTAssertEqual(imported.sections.first?.subdivision, .eighth)
    }

    // MARK: - JSON key-stripping helpers (simulate a pre-field file without depending on wire formats)

    private func stripKeys(_ keys: [String], fromObjectIn data: Data) throws -> Data {
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for k in keys { obj.removeValue(forKey: k) }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    /// Removes every `pickupTicks` key from an exported song wrapper (`{ version, song: { sections: [...] } }`),
    /// so it faithfully mimics a `.maelzelsong` written before the pickup fields existed.
    private func strippingPickupsFromExport(_ data: Data) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if var song = root["song"] as? [String: Any] {
            song.removeValue(forKey: "pickupTicks")
            if var sections = song["sections"] as? [[String: Any]] {
                sections = sections.map { var s = $0; s.removeValue(forKey: "pickupTicks"); return s }
                song["sections"] = sections
            }
            root["song"] = song
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}
