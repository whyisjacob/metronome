import XCTest
import AVFoundation
@testable import Metronome

/// Song-mode proof that muting composes with sections, per-section voice, and pickup pre-rolls — silencing
/// output without touching timing. Renders the REAL song path (`renderOfflineSong`) offline and confronts
/// the PCM with a first-principles grid (reusing `OfflineRenderAccuracyTests.detectOnsets`), never reading
/// expectations back from `SongPlan`.
final class SongMuteRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    private func peak(of samples: [Float]) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    private func installShortVoice(_ engine: MetronomeEngine) {
        let tok = [Float](repeating: 0.5, count: Int(0.010 * sampleRate))
        engine.installSyntheticVoiceTablesForTesting(
            numbers: [[Float]](repeating: tok, count: 32),
            syllables: [[Float]](repeating: tok, count: VoiceSyllable.allCases.count),
            sampleRate: sampleRate)
    }

    // MARK: - Muting a whole song: silent, but section timing + count are unchanged

    func testSongMuteIsSilentButSectionTimingAndCountAreUnchanged() throws {
        // Two sections at different tempos → a boundary. Classic click (no voice).
        //   A: 120 BPM 4/4 quarter, 1 bar → 4 clicks, frames/tick = 0.5 s.
        //   B:  90 BPM 3/4 quarter, 1 bar → 3 clicks, frames/tick = 60/90 s.
        let song = Song(name: "M", sections: [
            SongSection(name: "A", tempoBPM: 120, timeSignature: .common,
                        subdivision: .quarter, bars: 1),
            SongSection(name: "B", tempoBPM: 90, timeSignature: TimeSignature(numerator: 3, denominator: 4),
                        subdivision: .quarter, bars: 1),
        ])
        let fptA = (60.0 / 120.0) * sampleRate
        let fptB = (60.0 / 90.0) * sampleRate
        let sectionBStart = Int((4.0 * fptA).rounded())   // section A = 4 ticks, rounded to samples ONCE
        let expectedClicks = 4 + 3

        // Unmuted: onsets land on the independent grid across the boundary.
        let e1 = MetronomeEngine(); try e1.prepareForOfflineRendering(sampleRate: sampleRate)
        let full = try e1.renderOfflineSong(song)
        let seqFull = e1.currentPulse.sequence
        let finishedFull = e1.currentPulse.songFinished
        e1.teardownOfflineRendering()

        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: full, minGap: Int(0.018 * sampleRate))
        XCTAssertEqual(onsets.count, expectedClicks, "unmuted song must click every beat of both sections")
        let base = onsets[0]
        for k in 0..<4 {
            XCTAssertLessThan(abs(Double(onsets[k] - base) - Double(k) * fptA), 1.5,
                "section A beat \(k) off the first-principles grid")
        }
        for j in 0..<3 {
            let ideal = Double(sectionBStart) + Double(j) * fptB
            XCTAssertLessThan(abs(Double(onsets[4 + j] - base) - ideal), 1.5,
                "section B beat \(j) off the first-principles grid (boundary misplaced?)")
        }
        XCTAssertTrue(finishedFull, "the unmuted song reaches its end")

        // Fully muted: pure silence, IDENTICAL render length, and the SAME pulse progression + end — so the
        // section timing and click count are provably unchanged by muting.
        let e2 = MetronomeEngine(); try e2.prepareForOfflineRendering(sampleRate: sampleRate)
        e2.setClickMuted(true); e2.setVoiceMuted(true)
        let muted = try e2.renderOfflineSong(song)
        let seqMuted = e2.currentPulse.sequence
        let finishedMuted = e2.currentPulse.songFinished
        e2.teardownOfflineRendering()

        XCTAssertLessThan(peak(of: muted), 0.001, "the muted song must render pure silence")
        XCTAssertEqual(muted.count, full.count, "muting must not change the rendered length — timing is unchanged")
        XCTAssertEqual(seqMuted, seqFull, "muting must not change how the song advances (same pulse count)")
        XCTAssertGreaterThanOrEqual(Int(seqMuted), expectedClicks, "every click still advances the song while silent")
        XCTAssertTrue(finishedMuted, "the muted song still reaches its end at the correct time")
    }

    // MARK: - A muted pickup still occupies the correct time

    func testSongPickupStillOccupiesCorrectTimeWhileMuted() throws {
        // A song-level pickup (anacrusis) before the first downbeat, in the first section's quarter grid.
        let section = SongSection(name: "A", tempoBPM: 120, timeSignature: .common,
                                  subdivision: .quarter, bars: 1)
        let withPickupSong = Song(name: "P", sections: [section], pickupTicks: 2)
        let noPickupSong = Song(name: "N", sections: [section])
        let fpt = (60.0 / 120.0) * sampleRate

        let e1 = MetronomeEngine(); try e1.prepareForOfflineRendering(sampleRate: sampleRate)
        let withPickup = try e1.renderOfflineSong(withPickupSong)
        e1.teardownOfflineRendering()

        let e0 = MetronomeEngine(); try e0.prepareForOfflineRendering(sampleRate: sampleRate)
        let withoutPickup = try e0.renderOfflineSong(noPickupSong)
        e0.teardownOfflineRendering()

        // The pickup lengthens the render by its lead-in span (~2 ticks = 2 × 0.5 s), tolerant of ±1 tick.
        let diff = withPickup.count - withoutPickup.count
        XCTAssertLessThan(abs(diff - Int((2.0 * fpt).rounded())), Int(fpt),
            "a 2-tick pickup should add ~2 ticks of lead-in time to the render")

        // Unmuted with pickup: audible lead-in clicks ON TOP of the bar's 4.
        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: withPickup, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThan(onsets.count, 4, "the pickup adds lead-in clicks before the bar")

        // Muted with pickup: silent, but the render length is IDENTICAL to unmuted — the pickup still
        // occupies exactly its time, silently (a muted pickup does not collapse or shift the schedule).
        let e2 = MetronomeEngine(); try e2.prepareForOfflineRendering(sampleRate: sampleRate)
        e2.setClickMuted(true); e2.setVoiceMuted(true)
        let mutedWithPickup = try e2.renderOfflineSong(withPickupSong)
        e2.teardownOfflineRendering()

        XCTAssertLessThan(peak(of: mutedWithPickup), 0.001, "the muted pickup + song must be silent")
        XCTAssertEqual(mutedWithPickup.count, withPickup.count,
            "the muted pickup occupies the correct time — render length identical to unmuted")
    }

    // MARK: - Count only composes with a per-section counting voice

    func testSongCountOnlyKeepsAVoiceSectionCountingWithTheClickMuted() throws {
        // A counting section on an eighth grid with subdivisions NOT spoken: the 4 beats speak (voice
        // channel), the 4 off-beats click (click channel). Count-only mutes the click → only the 4 spoken
        // beats survive, proving per-section voice + the mute channels compose.
        var section = SongSection(name: "A", tempoBPM: 120, timeSignature: .common,
                                  subdivision: .eighth, bars: 1)
        section.voiceEnabled = true
        section.speakSubdivisions = false
        let song = Song(name: "V", sections: [section], voiceEnabled: true)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        installShortVoice(engine)
        engine.setClickMuted(true)      // Count only
        engine.setVoiceMuted(false)
        let samples = try engine.renderOfflineSong(song)

        XCTAssertGreaterThan(peak(of: samples), 0.1, "a counting section still counts aloud with the click muted")
        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertEqual(onsets.count, 4, "only the 4 spoken beats survive; the clicked off-beats are muted")
    }
}
