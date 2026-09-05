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
            VC(sub: .eighth,     tpb: 2, label: "eighth (1 and)"),
            VC(sub: .triplet,    tpb: 3, label: "triplet (1 trip let)"),
            VC(sub: .sixteenth,  tpb: 4, label: "sixteenth (1 e and a)"),
            // A tuplet: the beat speaks its number, the four in-between ticks click — a sound on every tick.
            VC(sub: .quintuplet, tpb: 5, label: "quintuplet (number + clicks)"),
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

    /// The engine HARD-CUTS a still-sounding spoken token at the next spoken onset, so successive counts
    /// never overlap or smear. Proven on the REAL offline render path with *synthetic* buffers, because a
    /// logic-test bundle carries no audio (the loader returns [] → clicks): we inject known-length spoken
    /// buffers, each far longer than the sixteenth interval, so a missing cut would pile several on top of
    /// one another. We assert the summed output never exceeds one buffer (no overlap) yet stays loud
    /// between onsets (a token really does play on every tick).
    func testSpokenTokensAreHardCutAndNeverOverlap() throws {
        let sr = sampleRate
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sr)
        defer { engine.teardownOfflineRendering() }

        // Constant-amplitude tokens, 0.6 s long — several times any subdivision interval here, so without
        // the hard-cut they would overlap (0.6 s / 0.167 s ≈ 4 tokens sounding at once).
        let amp: Float = 0.5
        let tokenLen = Int(0.6 * sr)
        let one = [Float](repeating: amp, count: tokenLen)
        let numbers = [[Float]](repeating: one, count: 32)
        let syllables = [[Float]](repeating: one, count: VoiceSyllable.allCases.count)
        engine.installSyntheticVoiceTablesForTesting(numbers: numbers, syllables: syllables, sampleRate: sr)

        let bpm = 90.0                      // sixteenth = 0.1667 s → .full tier: all four tokens speak & cut
        let tpb = 4
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                            subdivision: .sixteenth, sound: .voice)
        let seconds = 4.0
        let samples = try engine.renderOffline(config: config, seconds: seconds)
        XCTAssertFalse(samples.isEmpty)

        let framesPerTick = (60.0 / bpm / Double(tpb)) * sr
        // Non-vacuous: a token is several times longer than the gap to the next onset, so if the engine did
        // NOT cut, tokens would demonstrably overlap.
        XCTAssertGreaterThan(tokenLen, Int(framesPerTick) * 3)

        // No overlap anywhere: at most one spoken token sounds at a time, so |output| never piles past one
        // buffer's amplitude (a small margin covers the few-ms declick as one token ramps out at the cut).
        let totalFrames = min(Int((seconds * sr).rounded()), samples.count)
        var maxAmp: Float = 0
        for i in 0..<totalFrames { maxAmp = max(maxAmp, abs(samples[i])) }
        XCTAssertLessThan(maxAmp, amp + 0.08,
                          "spoken tokens overlapped — amplitude piled up past a single buffer (\(maxAmp))")

        // …yet a token really is sounding across each interval: sample the midpoint between consecutive
        // onsets (away from the declick notch at the cut) and require it to be loud.
        var tick = 1
        var checked = 0
        while true {
            let midFrame = Int((Double(tick) - 0.5) * framesPerTick)
            if midFrame + 1 >= totalFrames { break }
            XCTAssertGreaterThan(abs(samples[midFrame]), amp - 0.1,
                "no spoken token sounding mid-interval before tick \(tick) — the count dropped out")
            tick += 1
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8, "too few intervals checked")
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
