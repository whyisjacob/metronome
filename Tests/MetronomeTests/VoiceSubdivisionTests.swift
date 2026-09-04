import XCTest
import AVFoundation
@testable import Metronome

/// Voice-mode subdivision counting (item 2). Two independent proofs:
///
///  1. **Which token per tick** — proven purely and deterministically in `ClickMathTests`
///     (`testVoiceToken…`): eighths "1 and", sixteenths "1 e and a", triplets "1 trip let", plus the
///     compound-group counting. No audio, no synthesizer.
///
///  2. **The schedule end-to-end (this file).** In Voice mode the engine must place a sound on EVERY
///     subdivision tick, sample-accurately on the first-principles grid. The onset frame is computed by
///     the *same* scheduling code the click accuracy tests already pin to the grid (the token is
///     triggered at the identical frame offset, and `VoiceSampleFactory` trims each spoken buffer so its
///     onset is at frame 0), so here we assert a sound is present at each subdivision tick frame — a
///     check that holds whether the tick sounds a spoken syllable or, in a headless renderer with no
///     speech synthesis, the click fallback.
final class VoiceSubdivisionTests: XCTestCase {

    private let sampleRate = 44_100.0

    private struct VC { let sub: Subdivision; let tpb: Int; let label: String }

    func testVoiceModePlacesASoundOnEverySubdivisionTick() throws {
        // ticksPerBeat hard-coded (musical meaning), so the grid is independent of the code under test.
        let cases = [
            VC(sub: .eighth,    tpb: 2, label: "eighth (1 and)"),
            VC(sub: .triplet,   tpb: 3, label: "triplet (1 trip let)"),
            VC(sub: .sixteenth, tpb: 4, label: "sixteenth (1 e and a)"),
        ]
        for c in cases {
            let bpm = 90.0
            let framesPerTick = (60.0 / bpm / Double(c.tpb)) * sampleRate
            let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                                subdivision: c.sub, sound: .voice)

            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let seconds = 6.0
            let samples = try engine.renderOffline(config: config, seconds: seconds)
            XCTAssertFalse(samples.isEmpty, "no audio for voice \(c.label)")

            // Playback starts on sample 0 (offline rendering has no hardware latency).
            var head: Float = 0
            for i in 0..<min(512, samples.count) { head = max(head, abs(samples[i])) }
            XCTAssertGreaterThan(head, 0.03, "voice \(c.label): nothing sounded at the first tick")

            // A sound must be present at (or right at the start of) every subdivision tick frame.
            let totalFrames = Int((seconds * sampleRate).rounded())
            var tick = 0
            var checked = 0
            while true {
                let f = Int((Double(tick) * framesPerTick).rounded())
                if f + 512 >= totalFrames { break }
                var peak: Float = 0
                for i in f..<(f + 512) { peak = max(peak, abs(samples[i])) }
                XCTAssertGreaterThan(peak, 0.03,
                    "voice \(c.label): no sound scheduled at subdivision tick \(tick) (frame \(f))")
                tick += 1
                checked += 1
            }
            XCTAssertGreaterThan(checked, 8, "voice \(c.label): too few ticks checked")
        }
    }

    /// The syllable pre-render is well-formed: either synthesis is unavailable in this environment (an
    /// empty table → the engine clicks subdivisions) or every syllable slot is present. Never crashes.
    func testVoiceSyllableFactoryIsWellFormed() {
        let table = VoiceSampleFactory.renderSyllables(sampleRate: sampleRate)
        XCTAssertTrue(table.isEmpty || table.count == VoiceSyllable.allCases.count,
                      "syllable table must be empty (no synthesis) or one buffer per syllable")
    }

    /// With the "count subdivisions" preference OFF, Voice mode speaks only the beats and clicks the
    /// in-between ticks — a sound must still land on EVERY tick so the count is never lost. Deterministic:
    /// the off-beat clicks regardless of whether speech synthesis is available in the environment. This
    /// also exercises the engine's `setSpeakSubdivisions(false)` gate.
    func testVoiceWithSubdivisionsOffStillSoundsEveryTick() throws {
        let bpm = 90.0
        let tpb = 4                                        // sixteenth (musical fact, hard-coded)
        let framesPerTick = (60.0 / bpm / Double(tpb)) * sampleRate
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                            subdivision: .sixteenth, sound: .voice)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setSpeakSubdivisions(false)

        let seconds = 4.0
        let samples = try engine.renderOffline(config: config, seconds: seconds)
        XCTAssertFalse(samples.isEmpty)

        let totalFrames = Int((seconds * sampleRate).rounded())
        var tick = 0
        var checked = 0
        while true {
            let f = Int((Double(tick) * framesPerTick).rounded())
            if f + 512 >= totalFrames { break }
            var peak: Float = 0
            for i in f..<(f + 512) { peak = max(peak, abs(samples[i])) }
            XCTAssertGreaterThan(peak, 0.03,
                "subdivisions-off voice: no sound at tick \(tick) (frame \(f)) — count lost")
            tick += 1
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8, "too few ticks checked")
    }
}
