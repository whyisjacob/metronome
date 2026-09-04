import XCTest
import AVFoundation
@testable import Metronome

/// Audio-level proof that the gap-click trainer (feature 1) silences the right beats **without touching
/// timing** — the surviving clicks stay exactly on the first-principles grid, and the count/visual (the
/// engine's pulse) keep advancing. This is the trainer's analogue of `testMutedBeatIsSilentButGridIsUnbroken`.
///
/// Crucially it also ties the pure `GapTrainer` decision to the real rendered audio: the silent beats in
/// the PCM are exactly the beats the model marks `.silence`, beat-for-beat.
final class TrainerRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0
    private let bpm = 120.0
    private var framesPerBeat: Double { (60.0 / bpm) * sampleRate }

    /// Peak magnitude in a short window straddling `frame` (a click's body sits just after its onset).
    private func peakNear(_ samples: [Float], _ frame: Int) -> Float {
        let start = max(0, frame - 32), end = min(frame + 400, samples.count)
        var p: Float = 0
        var i = start
        while i < end { p = max(p, abs(samples[i])); i += 1 }
        return p
    }

    func testBarsModeSilencesOffBarsButKeepsTheGrid() throws {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = false; t.barsOn = 1; t.barsOff = 1

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setTrainer(t)

        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: .quarter)
        let bars = 4
        let seconds = Double(bars * 4) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        // Per-beat: bars 0 and 2 (even = on) sound; bars 1 and 3 (odd = off) are silent.
        for beat in 0..<(bars * 4) {
            let bar = beat / 4
            let frame = Int(Double(beat) * framesPerBeat)
            if bar % 2 == 0 {
                XCTAssertGreaterThan(peakNear(samples, frame), 0.05, "on-bar beat \(beat) should sound")
            } else {
                XCTAssertLessThan(peakNear(samples, frame), 0.05, "off-bar beat \(beat) should be silent")
            }
        }

        // Timing is untouched: every surviving onset lands on the quarter grid, in an on-bar slot.
        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThan(onsets.count, 4, "on bars must still sound")
        let base = onsets[0]
        for onset in onsets {
            let n = Int((Double(onset - base) / framesPerBeat).rounded())
            XCTAssertEqual((n / 4) % 2, 0, "a surviving onset fell in an off bar — trainer muted the wrong beat")
            XCTAssertLessThan(abs(Double(onset - base) - Double(n) * framesPerBeat), 2.0,
                              "a surviving onset drifted off the grid — the trainer must not shift timing")
        }
    }

    func testSoftDownbeatSoundsButQuieterInOffBars() throws {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = true; t.barsOn = 1; t.barsOff = 1

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setTrainer(t)

        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: .quarter)
        let seconds = Double(4 * 4) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        func frame(_ beat: Int) -> Int { Int(Double(beat) * framesPerBeat) }
        let onDownbeat = peakNear(samples, frame(0))    // bar 0 (on), strong downbeat
        let offDownbeat = peakNear(samples, frame(4))   // bar 1 (off), kept-soft downbeat

        XCTAssertGreaterThan(offDownbeat, 0.05, "the off-bar downbeat must still sound (soft reference)")
        XCTAssertGreaterThan(onDownbeat, offDownbeat, "the kept downbeat must be softer than a normal downbeat")
        // The rest of the off bar is genuinely silent.
        XCTAssertLessThan(peakNear(samples, frame(5)), 0.05, "off-bar beat 2 must be silent")
        XCTAssertLessThan(peakNear(samples, frame(6)), 0.05, "off-bar beat 3 must be silent")
        XCTAssertLessThan(peakNear(samples, frame(7)), 0.05, "off-bar beat 4 must be silent")
    }

    /// The rendered audio matches the pure model beat-for-beat: exactly the beats the trainer marks
    /// `.silence` are silent in the PCM, and the rest sound — at 50% random with a fixed seed.
    func testRandomAudioMatchesTheModelBeatForBeat() throws {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .random; t.keepDownbeat = false
        t.mutePercent = 50; t.seed = 0x1357_9BDF_2468_ACE0

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setTrainer(t)

        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: .quarter)
        let bars = 8, beatsPerBar = 4
        let seconds = Double(bars * beatsPerBar) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        var silentCount = 0
        for beat in 0..<(bars * beatsPerBar) {
            let expectedSilent = t.gate(globalBeat: beat, beatsPerBar: beatsPerBar, posInBeat: 0) == .silence
            let peak = peakNear(samples, Int(Double(beat) * framesPerBeat))
            if expectedSilent {
                silentCount += 1
                XCTAssertLessThan(peak, 0.05, "beat \(beat) is marked silence but sounded")
            } else {
                XCTAssertGreaterThan(peak, 0.05, "beat \(beat) is marked play but was silent")
            }
        }
        // Sanity: a 50% pattern silenced a meaningful share (not degenerate all/none).
        XCTAssertGreaterThan(silentCount, 4, "50% random should silence a fair share of \(bars * beatsPerBar) beats")
        XCTAssertLessThan(silentCount, bars * beatsPerBar - 4, "…but not nearly all of them")
    }
}
