import XCTest
import AVFoundation
@testable import Metronome

/// Proof that muting is a pure OUTPUT gate — it changes only WHAT sounds, never WHEN. These render the
/// REAL `MetronomeEngine` offline (the same `AVAudioSourceNode` callback the accuracy suites use) and
/// confront the produced PCM with a first-principles grid, exactly like `OfflineRenderAccuracyTests`
/// (whose `detectOnsets` is reused). The expectations are hand-derived from the musical definition, never
/// read back from `RenderPlan`/`SongPlan`.
///
/// The central test renders the SAME configuration muted and unmuted and asserts the surviving onset
/// frames are BYTE-IDENTICAL to the corresponding unmuted onsets — muting removes amplitude, nothing else.
final class MuteRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// A short synthetic spoken buffer so each spoken token reads as ONE onset (its length is under the
    /// 18 ms detection guard) and a logic-test bundle needs no bundled voice `.wav`.
    private func installShortVoice(_ engine: MetronomeEngine) {
        let tok = [Float](repeating: 0.5, count: Int(0.010 * sampleRate))
        engine.installSyntheticVoiceTablesForTesting(
            numbers: [[Float]](repeating: tok, count: 32),
            syllables: [[Float]](repeating: tok, count: VoiceSyllable.allCases.count),
            sampleRate: sampleRate)
    }

    private func peak(of samples: [Float]) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    // MARK: - The important one: timing invariance under muting

    /// Voice sound, 4/4 eighth @120 with subdivisions NOT spoken: the beats SPEAK (voice channel) and the
    /// off-beats CLICK (click channel) — two independent channels on one eighth grid. Rendering the SAME
    /// config three ways (nothing muted / click muted / voice muted) must place every surviving onset on
    /// byte-identical frames: muting only zeroes a channel's amplitude.
    func testMutingChangesAmplitudeOnlyNeverOnsetPositions() throws {
        let config = MetronomeConfiguration(bpm: 120, timeSignature: .common,
                                            subdivision: .eighth, sound: .voice)
        let seconds = 3.0
        // First principles: an eighth at 120 BPM lasts (60/120)/2 = 0.25 s.
        let framesPerEighth = (60.0 / 120.0) / 2.0 * sampleRate

        func onsets(clickMuted: Bool, voiceMuted: Bool) throws -> [Int] {
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }
            installShortVoice(engine)
            engine.setSpeakSubdivisions(false)     // off-beats click, beats speak
            engine.setClickMuted(clickMuted)
            engine.setVoiceMuted(voiceMuted)
            let samples = try engine.renderOffline(config: config, seconds: seconds)
            return OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        }

        let full = try onsets(clickMuted: false, voiceMuted: false)
        let clickMuted = try onsets(clickMuted: true, voiceMuted: false)
        let voiceMuted = try onsets(clickMuted: false, voiceMuted: true)

        XCTAssertGreaterThan(full.count, 8, "need several eighths to prove invariance")
        let base = full[0]
        XCTAssertLessThanOrEqual(base, 1, "offline render begins on sample 0")

        // Independent grid: every unmuted eighth onset is on the first-principles grid, drift-free.
        for k in 0..<full.count {
            XCTAssertLessThan(abs(Double(full[k] - base) - Double(k) * framesPerEighth), 1.5,
                "unmuted onset \(k) is off the first-principles eighth grid")
        }

        // Beats are the EVEN eighths (spoken), off-beats the ODD (clicked). Muting a channel drops that
        // channel's onsets but must leave the survivors on EXACTLY the same frames as when nothing is muted.
        let beatFrames = stride(from: 0, to: full.count, by: 2).map { full[$0] }
        let offbeatFrames = stride(from: 1, to: full.count, by: 2).map { full[$0] }
        XCTAssertEqual(clickMuted, beatFrames,
            "click-mute must leave the spoken-beat onsets on byte-identical frames — the grid is unchanged")
        XCTAssertEqual(voiceMuted, offbeatFrames,
            "voice-mute must leave the clicked off-beat onsets on byte-identical frames — the grid is unchanged")
    }

    // MARK: - Click muted → silent, but the plan still clicks every beat

    func testClickMuteIsSilentButThePlanStillClicksEveryBeat() throws {
        let config = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter)
        let seconds = 2.0

        // Unmuted: 120 BPM over 2 s → quarter clicks at 0 / 0.5 / 1.0 / 1.5 s (the 2.0 s beat is past the
        // window) = 4, from first principles.
        let engineFull = MetronomeEngine()
        try engineFull.prepareForOfflineRendering(sampleRate: sampleRate)
        let full = try engineFull.renderOffline(config: config, seconds: seconds)
        let fullOnsets = OfflineRenderAccuracyTests.detectOnsets(in: full, minGap: Int(0.018 * sampleRate))
        engineFull.teardownOfflineRendering()
        XCTAssertEqual(fullOnsets.count, 4, "first principles: 4 quarter clicks in 2 s at 120 BPM")

        // Click muted: pure silence, but the engine advanced the grid identically — a pulse per tick.
        let engineMuted = MetronomeEngine()
        try engineMuted.prepareForOfflineRendering(sampleRate: sampleRate)
        engineMuted.setClickMuted(true)
        let muted = try engineMuted.renderOffline(config: config, seconds: seconds)
        let seq = engineMuted.currentPulse.sequence
        engineMuted.teardownOfflineRendering()

        XCTAssertLessThan(peak(of: muted), 0.001, "click-muted output must be silent")
        XCTAssertEqual(Int(seq), fullOnsets.count,
            "the plan's click count is unchanged — the tick grid advances identically while muted")
    }

    // MARK: - Count only → voice audible, click silent

    func testCountOnlyKeepsTheSpokenCountAndSilencesTheClick() throws {
        // Voice eighth @120, subdivisions not spoken: beats speak, off-beats click. Count-only mutes click.
        let config = MetronomeConfiguration(bpm: 120, timeSignature: .common,
                                            subdivision: .eighth, sound: .voice)
        let seconds = 2.0
        let framesPerBeat = (60.0 / 120.0) * sampleRate      // a beat every 0.5 s

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        installShortVoice(engine)
        engine.setSpeakSubdivisions(false)
        engine.setClickMuted(true)      // Count only: click muted…
        engine.setVoiceMuted(false)     // …voice audible
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        func peakNear(_ frame: Int) -> Float {
            let start = max(0, frame - 40), end = min(frame + 500, samples.count)
            var p: Float = 0, i = start
            while i < end { p = max(p, abs(samples[i])); i += 1 }
            return p
        }
        // Beats (0 / 0.5 / 1.0 / 1.5 s) are spoken → audible; the off-beat click positions are silent.
        for b in 0..<4 {
            XCTAssertGreaterThan(peakNear(Int(Double(b) * framesPerBeat)), 0.1,
                "beat \(b) must be counted aloud in Count only")
            let offbeat = Int((Double(b) + 0.5) * framesPerBeat)
            XCTAssertLessThan(peakNear(offbeat), 0.02,
                "the off-beat click at position \(b) must be silent in Count only")
        }
    }

    // MARK: - Flash only → silent, but the beat state advances per beat

    func testFlashOnlyIsSilentButTheBeatStateAdvancesPerBeat() throws {
        let config = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter)
        let seconds = 2.0

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        engine.setClickMuted(true)
        engine.setVoiceMuted(true)      // flash only: all audio muted
        let samples = try engine.renderOffline(config: config, seconds: seconds)
        let seq = engine.currentPulse.sequence
        let lastTick = engine.currentPulse.tickIndex
        engine.teardownOfflineRendering()

        XCTAssertLessThan(peak(of: samples), 0.001, "flash-only must render pure silence")
        XCTAssertEqual(Int(seq), 4, "the visual/beat state must still advance once per beat (4 quarters in 2 s)")
        XCTAssertEqual(lastTick, 3, "the last advanced tick is beat index 3 (0-based) — the grid ran to the end")
    }

    // MARK: - Unmuted render is byte-for-byte the classic click (the accuracy baseline is untouched)

    /// Belt-and-suspenders: with nothing muted, muting the (absent) voice channel of a pure click config
    /// changes NOTHING — the samples are byte-for-byte identical to a plain render. This is the guarantee
    /// the accuracy suites rely on: they never mute, so their audio is exactly as before.
    func testUnmutedAndVoiceMutedClickConfigAreByteIdentical() throws {
        let config = MetronomeConfiguration(bpm: 100, timeSignature: .common, subdivision: .sixteenth)
        let seconds = 2.0

        let e1 = MetronomeEngine(); try e1.prepareForOfflineRendering(sampleRate: sampleRate)
        let plain = try e1.renderOffline(config: config, seconds: seconds)
        e1.teardownOfflineRendering()

        let e2 = MetronomeEngine(); try e2.prepareForOfflineRendering(sampleRate: sampleRate)
        e2.setVoiceMuted(true)   // no voice content in a click config → a no-op on the samples
        let voiceMuted = try e2.renderOffline(config: config, seconds: seconds)
        e2.teardownOfflineRendering()

        XCTAssertEqual(plain, voiceMuted,
            "muting a channel that carries no content must not perturb the click samples at all")
    }
}
