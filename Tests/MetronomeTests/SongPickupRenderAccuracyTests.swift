import XCTest
import AVFoundation
@testable import Metronome

/// Audio-level proof that a song-mode pickup / count-in is genuinely AUDIBLE and lands on the exact grid
/// before a STRONG downbeat — rendered through the real `MetronomeEngine` offline song path (the same code
/// that runs live). The oracle is first-principles only: a beat lasts `60 / BPM` seconds, so the pickup
/// beats and the downbeat sit on the uniform `round(j · 60/BPM · sampleRate)` grid — NEVER read from
/// `SongPlan`/`SongPreroll`/`RenderPlan`.
///
/// It also proves the subtle, musically essential invariant: the pickup plays ONCE on start / seek and is
/// NEVER replayed on a continuous pass through a section (which would inject phantom beats).
final class SongPickupRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    private func peak(_ samples: [Float], at frame: Int, window: Int = 400) -> Float {
        let start = max(0, frame - 32), end = min(frame + window, samples.count)
        var p: Float = 0
        var i = start
        while i < end { p = max(p, abs(samples[i])); i += 1 }
        return p
    }

    private func onsets(_ samples: [Float]) -> [Int] {
        SongOfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
    }

    // MARK: - (1) Song-start pickup: on the grid, before a strong downbeat, played once

    /// A song-level 2-beat pickup in 4/4 @120 leads in before the song's first downbeat. Playback begins on
    /// the first pickup tick (sample 0); the two pickup beats and the downbeat sit one quarter apart on the
    /// first-principles grid; the downbeat carries the STRONG accent (louder than the pickup and the beat
    /// after it); and the pickup adds exactly its ticks — it is not replayed for the second bar.
    func testSongStartPickupOnGridBeforeStrongDownbeat() throws {
        let bpm = 120.0
        let framesPerBeat = (60.0 / bpm) * sampleRate
        let section = SongSection(name: "A", tempoBPM: bpm, timeSignature: .common, subdivision: .quarter, bars: 2)
        let song = Song(name: "P", sections: [section], pickupTicks: 2)     // 2-beat song-start pickup

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSong(song)
        let hits = onsets(samples)

        // 2 pickup beats + 2 bars × 4 beats = 10 onsets. The pickup plays ONCE (not once per bar).
        let plainClicks = SongPlan(song: song, sampleRate: sampleRate).clickCount    // 8, pickup NOT in the plan
        XCTAssertEqual(hits.count, plainClicks + 2, "expected the 2 pickup beats plus the plain 8-beat grid")

        let base = hits[0]
        XCTAssertLessThanOrEqual(base, 1, "playback must begin on the first pickup tick at sample 0")

        // The 2 pickup beats (0,1) and the downbeat (2) sit on the uniform quarter grid, one beat apart.
        for j in 0...2 {
            let ideal = Double(j) * framesPerBeat
            XCTAssertLessThan(abs(Double(hits[j] - base) - ideal), 2.0,
                "onset \(j) off the first-principles grid")
        }

        // The downbeat (onset 2) is the STRONG accent: louder than both pickup beats and the next beat.
        let downbeat = peak(samples, at: hits[2])
        XCTAssertLessThan(peak(samples, at: hits[0]), downbeat, "pickup beat 0 must be weaker than the downbeat")
        XCTAssertLessThan(peak(samples, at: hits[1]), downbeat, "pickup beat 1 must be weaker than the downbeat")
        XCTAssertGreaterThan(downbeat, peak(samples, at: hits[3]), "the downbeat must be the strong accent")
    }

    /// A sub-beat song pickup renders on the grid too: an eighth-grid 1-tick pickup (the "& of 4") sounds a
    /// half-beat before the downbeat, and the downbeat is the strong accent.
    func testSubBeatSongPickupOnGrid() throws {
        let bpm = 120.0
        let framesPerBeat = (60.0 / bpm) * sampleRate
        let section = SongSection(name: "A", tempoBPM: bpm, timeSignature: .common, subdivision: .eighth, bars: 1)
        let song = Song(name: "P", sections: [section], pickupTicks: 1)     // the "& of 4"

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSong(song)
        let hits = onsets(samples)
        XCTAssertGreaterThan(hits.count, 3)
        let base = hits[0]
        XCTAssertLessThanOrEqual(base, 1, "the '& of 4' pickup starts playback on sample 0")
        // The downbeat lands exactly one eighth after the pickup, and it is the strong accent.
        XCTAssertLessThan(abs(Double(hits[1] - base) - framesPerBeat / 2), 2.0,
            "the downbeat must land one eighth after the '& of 4' pickup")
        XCTAssertGreaterThan(peak(samples, at: hits[1]), peak(samples, at: hits[0]),
            "the downbeat after the sub-beat pickup must be the strong accent")
    }

    // MARK: - (2) Section pickup: plays on SEEK, but NOT on a continuous pass

    /// Section B carries a 2-beat pickup. Playing the song straight through (A → B, no song pickup) must NOT
    /// replay B's pickup — the continuous pass is exactly the plain grid. This is the subtle invariant: a
    /// pickup is a one-time lead-in, never injected mid-song.
    func testSectionPickupNotReplayedOnContinuousPass() throws {
        let a = SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .quarter, bars: 1)
        let b = SongSection(name: "B", tempoBPM: 120, timeSignature: .common, subdivision: .quarter, bars: 1,
                            pickupTicks: 2)
        let song = Song(name: "AB", sections: [a, b])            // NO song-start pickup

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSong(song)
        let hits = onsets(samples)
        let plainClicks = SongPlan(song: song, sampleRate: sampleRate).clickCount   // 4 + 4 = 8
        XCTAssertEqual(hits.count, plainClicks,
            "a continuous pass must NOT replay section B's pickup (would be \(plainClicks + 2), not \(plainClicks))")
    }

    /// The same section B pickup DOES play when you SEEK to B: two pickup beats then B's downbeat, one beat
    /// apart on the grid, downbeat strong. Proves the pickup is reachable/audible exactly at a start/seek.
    func testSectionPickupPlaysOnSeek() throws {
        let bpm = 120.0
        let framesPerBeat = (60.0 / bpm) * sampleRate
        let a = SongSection(name: "A", tempoBPM: bpm, timeSignature: .common, subdivision: .quarter, bars: 1)
        let b = SongSection(name: "B", tempoBPM: bpm, timeSignature: .common, subdivision: .quarter, bars: 1,
                            pickupTicks: 2)
        let song = Song(name: "AB", sections: [a, b])

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSongSeeking(song, toSection: 1)
        let hits = onsets(samples)

        // 2 pickup beats + B's 4 beats = 6 onsets.
        XCTAssertEqual(hits.count, 6, "seek to B must play its 2-beat pickup then B's 4 beats")
        let base = hits[0]
        XCTAssertLessThanOrEqual(base, 1, "the seek pickup starts playback on sample 0")
        XCTAssertLessThan(abs(Double(hits[1] - base) - framesPerBeat), 2.0, "pickup beats one quarter apart")
        // The downbeat lands exactly one beat after the FINAL pickup tick.
        XCTAssertLessThan(abs(Double(hits[2] - hits[1]) - framesPerBeat), 2.0,
            "the downbeat must land one beat after the final pickup tick")
        XCTAssertGreaterThan(peak(samples, at: hits[2]), peak(samples, at: hits[0]),
            "the section downbeat after the pickup must be the strong accent")
    }

    // MARK: - (3) Song mode counts out loud (the Task B voice path is audible)

    /// A section that counts out loud SPEAKS its beats through the real song render path. With synthetic
    /// constant-amplitude spoken buffers (a logic-test bundle carries no voice `.wav`), each beat is the
    /// injected 0.5 — audibly the spoken number, NOT a classic click (strong 1.0 / normal 0.72). Proves the
    /// song-mode voice path exists and sounds; the per-section override turns it on over an off song global.
    func testSongCountsOutLoudAudibly() throws {
        let bpm = 100.0
        let framesPerBeat = (60.0 / bpm) * sampleRate
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        // Install AFTER prepare (which resets the voice table); the rate is marked rendered so the lazy
        // loader can't clobber it. A constant 0.5 buffer, plainly distinct from any click amplitude.
        let amp: Float = 0.5
        let one = [Float](repeating: amp, count: Int(0.15 * sampleRate))
        engine.installSyntheticVoiceTablesForTesting(numbers: [[Float]](repeating: one, count: 32),
                                                     syllables: [[Float]](repeating: one, count: VoiceSyllable.allCases.count),
                                                     sampleRate: sampleRate)

        let section = SongSection(name: "A", tempoBPM: bpm, timeSignature: .common, subdivision: .quarter,
                                  bars: 1, voiceEnabled: true)              // section overrides the song global
        let song = Song(name: "V", sections: [section], voiceEnabled: false)
        let samples = try engine.renderOfflineSong(song)

        for beat in 0..<4 {
            let p = peak(samples, at: Int(Double(beat) * framesPerBeat))
            XCTAssertEqual(p, amp, accuracy: 0.12, "beat \(beat) must SPEAK its number (~0.5), not click")
            XCTAssertLessThan(p, 0.7, "a spoken beat is quieter than a classic click — Voice actually sounded")
        }
    }

    /// Opting a section OUT of its start pickup (`startWithPickup == false`) means a seek to it jumps straight
    /// to the downbeat — no lead-in — even though `pickupTicks` is set (the user's per-section choice).
    func testSectionPickupSuppressedWhenStartWithPickupOff() throws {
        let a = SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .quarter, bars: 1)
        let b = SongSection(name: "B", tempoBPM: 120, timeSignature: .common, subdivision: .quarter, bars: 1,
                            pickupTicks: 2, startWithPickup: false)
        let song = Song(name: "AB", sections: [a, b])

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSongSeeking(song, toSection: 1)
        let hits = onsets(samples)
        XCTAssertEqual(hits.count, 4, "with startWithPickup off, seek to B plays B's 4 beats and no lead-in")
    }
}
