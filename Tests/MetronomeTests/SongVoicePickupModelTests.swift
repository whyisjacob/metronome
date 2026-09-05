import XCTest
@testable import Metronome

/// Pure, deterministic proofs for the song-mode pickup lead-in (`SongPreroll`) and per-section Voice
/// (`SongVoicePlan` / `SongPlan`), built from FIRST PRINCIPLES — never read back from the code under test:
///
///   * Pre-roll frames are confronted with an independently hand-derived grid at a clean sample rate.
///   * Pre-roll counting tokens are the tail-of-bar numbers/syllables per meter (the task's table).
///   * Pre-roll ticks are metrically weak (never `.strong`); the following downbeat IS `.strong`.
///   * Per-section Voice override vs inheritance resolves exactly.
final class SongVoicePickupModelTests: XCTestCase {

    // MARK: - Pre-roll frames on the first-principles grid (clean 48 kHz → integer frames)

    /// A 2-beat pickup in 4/4 @120 at 48 kHz: `fpt = (60/120)/1 × 48000 = 24000`, bar `B = 4`. Pickup tick
    /// `j` (extended bar-tick `B−p+j`) sits `round(B·fpt) − round((B−p+j)·fpt)` frames BEFORE the downbeat —
    /// computed here by hand, never from `SongPreroll`. The downbeat is exactly one beat after the last tick.
    func testPrerollFramesMatchHandDerivedGrid() {
        let sr = 48_000.0, fpt = 24_000, B = 4, p = 2
        let downbeat = 500_000     // arbitrary anchor; assertions are relative to it
        let section = SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .quarter)
        let preroll = SongPreroll(section: section, pickupTicks: p, downbeatFrame: downbeat, sampleRate: sr)

        XCTAssertEqual(preroll.clicks.count, p)
        func expectedOffset(_ j: Int) -> Int {   // independent oracle
            Int((Double(B) * Double(fpt))) - Int((Double(B - p + j) * Double(fpt)))
        }
        for j in 0..<p {
            XCTAssertEqual(downbeat - preroll.clicks[j].frame, expectedOffset(j),
                "pickup tick \(j) off the hand-derived grid")
        }
        // The downbeat lands exactly ONE beat (one tick on this quarter grid) after the final pickup tick.
        XCTAssertEqual(downbeat - preroll.clicks[p - 1].frame, fpt,
            "the downbeat must land exactly one beat after the final pickup tick")
        XCTAssertEqual(preroll.span, expectedOffset(0), "the lead-in span is the distance from tick 0")
    }

    // MARK: - Pre-roll counting tokens are the tail-of-bar numbers per meter (the task's table)

    private func prerollTokens(_ section: SongSection, _ ticks: Int) -> [VoiceToken] {
        SongPreroll(section: section, pickupTicks: ticks, downbeatFrame: 0, sampleRate: 48_000).clicks.map { $0.token }
    }

    func testPickupTailTokensPerMeter() {
        // 4/4, 2-beat pickup → "3, 4".
        XCTAssertEqual(prerollTokens(SongSection(timeSignature: .common, subdivision: .quarter), 2),
                       [.number(2), .number(3)])
        // 3/4, 1-beat pickup → "3".
        XCTAssertEqual(prerollTokens(SongSection(timeSignature: TimeSignature(numerator: 3, denominator: 4),
                                                 subdivision: .quarter), 1),
                       [.number(2)])
        // 12/8 felt in 4 (dotted-quarter beat), 1-beat pickup → "4".
        XCTAssertEqual(prerollTokens(SongSection(timeSignature: TimeSignature(numerator: 12, denominator: 8),
                                                 subdivision: .quarter), 1),
                       [.number(3)])
        // Sub-beat: eighth grid, 1-tick pickup → the "& of 4".
        XCTAssertEqual(prerollTokens(SongSection(timeSignature: .common, subdivision: .eighth), 1),
                       [.syllable(.and)])
        // Sub-beat: sixteenth grid, 2-tick pickup → "and, a".
        XCTAssertEqual(prerollTokens(SongSection(timeSignature: .common, subdivision: .sixteenth), 2),
                       [.syllable(.and), .syllable(.a)])
    }

    // MARK: - Pre-roll ticks are never strong; the following downbeat IS strong

    func testPickupTicksNeverStrongDownbeatIsStrong() {
        // A hostile pattern: beat 4 is user-accented STRONG. A 2-beat pickup covers beats 3 and 4, so the
        // last pickup tick would be strong — the pre-roll must clamp it (a pickup is metrically weak).
        let section = SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .quarter,
                                  accentPattern: [.strong, .normal, .normal, .strong], bars: 1, pickupTicks: 2)
        let preroll = SongPreroll(section: section, pickupTicks: 2, downbeatFrame: 0, sampleRate: 48_000)
        XCTAssertEqual(preroll.clicks.count, 2)
        XCTAssertTrue(preroll.clicks.allSatisfy { $0.accent != .strong },
            "a pickup tick is metrically weak — never the strong beat")
        XCTAssertEqual(preroll.clicks[1].accent, .medium, "a would-be-strong tail beat is clamped to medium")

        // The real downbeat (the section's first click) IS strong.
        let plan = SongPlan(song: Song(name: "S", sections: [section]), sampleRate: 48_000)
        XCTAssertEqual(plan.accent(at: 0), .strong, "the downbeat after the pickup must be the strong accent")
    }

    // MARK: - Per-section Voice override vs inheritance

    func testVoiceInheritanceResolvesPerSection() {
        let sections = [
            SongSection(name: "inherit"),                                   // voiceEnabled nil → inherit
            SongSection(name: "forceOff", voiceEnabled: false),            // override off
            SongSection(name: "forceOn", voiceEnabled: true,               // override on, speak subs off
                        speakSubdivisions: false),
        ]
        let songOn = Song(name: "S", sections: sections, voiceEnabled: true)
        let onPlan = SongVoicePlan.resolve(song: songOn, globalSpeakSubdivisions: true)
        XCTAssertEqual(onPlan.voiceEnabled, [true, false, true], "inherit=on, override off, override on")
        XCTAssertEqual(onPlan.speakSubdivisions, [true, true, false], "inherit=global(on), inherit=global, override off")
        XCTAssertTrue(onPlan.anyVoiceEnabled)

        let songOff = Song(name: "S", sections: sections, voiceEnabled: false)
        let offPlan = SongVoicePlan.resolve(song: songOff, globalSpeakSubdivisions: false)
        XCTAssertEqual(offPlan.voiceEnabled, [false, false, true], "inherit=off, override off, override on")
        XCTAssertEqual(offPlan.speakSubdivisions, [false, false, false])
    }

    // MARK: - SongPlan carries the per-click Voice tokens only when voice is attached

    func testSongPlanVoiceTokensAndInheritance() {
        let section = SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .eighth,
                                  bars: 1, voiceEnabled: true)
        let song = Song(name: "S", sections: [section], voiceEnabled: false)   // section overrides to on
        let voice = SongVoicePlan.resolve(song: song, globalSpeakSubdivisions: true)
        let plan = SongPlan(song: song, sampleRate: 44_100, voice: voice)

        XCTAssertTrue(plan.voiceEnabled(at: 0), "the section overrides the (off) song global to count out loud")
        // 4/4 eighth: "1 & 2 & 3 & 4 &" — tokens on the eighth grid.
        XCTAssertEqual(plan.voiceToken(at: 0), .number(0))       // "1"
        XCTAssertEqual(plan.voiceToken(at: 1), .syllable(.and))  // "&"
        XCTAssertEqual(plan.voiceToken(at: 2), .number(1))       // "2"
        XCTAssertTrue(plan.speaksToken(at: 0), "a beat number always speaks")

        // A plan built WITHOUT voice is the classic-click path: no voice, tokens are `.none`.
        let plain = SongPlan(song: song, sampleRate: 44_100)
        XCTAssertFalse(plain.voiceEnabled(at: 0))
        XCTAssertEqual(plain.voiceToken(at: 0), .none)
    }

    // MARK: - Backward-compatible round-trips of the new fields

    func testNewSectionAndSongFieldsRoundTrip() throws {
        let song = Song(name: "R",
                        sections: [SongSection(name: "A", subdivision: .eighth, pickupTicks: 1,
                                               startWithPickup: false, voiceEnabled: true,
                                               speakSubdivisions: false)],
                        pickupTicks: 2, voiceEnabled: true)
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(decoded, song)
        XCTAssertEqual(decoded.voiceEnabled, true)
        XCTAssertEqual(decoded.sections.first?.startWithPickup, false)
        XCTAssertEqual(decoded.sections.first?.voiceEnabled, true)
        XCTAssertEqual(decoded.sections.first?.speakSubdivisions, false)
    }
}
