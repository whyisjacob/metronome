import XCTest
import AVFoundation
@testable import Metronome

/// Tests for the Voice-quality work (feature 2): the pure, headless-testable pieces (trim-both-ends,
/// aggressive syllable compaction, the fast-tempo speak-vs-click threshold) plus an end-to-end proof that
/// at a fast tempo the count is never lost — a sound still lands on every subdivision tick.
///
/// The Voice sound now plays PRE-GENERATED bundled clips (see `VoiceSampleFactory`), not live speech, so
/// there is no on-device synthesizer or voice catalog to rank. The clips' actual *sound* can't be
/// asserted in a headless renderer (the unit-test bundle may not carry the app's audio resources — the
/// loader then returns `[]` and the engine clicks); the timing decisions that govern Voice mode are
/// unit-tested directly here and on the sample-accurate click grid.
final class VoiceQualityTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Trim leading AND trailing silence

    func testTrimSilenceTrimsBothEnds() {
        let input: [Float] = [0, 0, 0, 0.5, -0.25, 0.75, 0, 0]
        XCTAssertEqual(VoiceSampleFactory.trimSilence(input), [0.5, -0.25, 0.75])
    }

    func testTrimSilencePreservesInternalDips() {
        // A quiet gap *inside* the token (e.g. between syllables) must be kept — only the outer silence goes.
        let input: [Float] = [0, 0.5, 0.0, 0.0, 0.5, 0]
        XCTAssertEqual(VoiceSampleFactory.trimSilence(input), [0.5, 0.0, 0.0, 0.5])
    }

    func testTrimSilenceAllSilenceReturnsEmpty() {
        XCTAssertTrue(VoiceSampleFactory.trimSilence([0, 0, 0.01, -0.01]).isEmpty,
                      "below-threshold everywhere ⇒ empty (engine reads that as 'no buffer → click')")
    }

    func testTrimSilenceNoOpWhenAlreadyTight() {
        let input: [Float] = [0.5, -0.5, 0.5]
        XCTAssertEqual(VoiceSampleFactory.trimSilence(input), input)
    }

    // MARK: - Fast-tempo: speak the subdivision only when it fits

    func testSpeaksSubdivisionSyllablesThreshold() {
        func plan(_ bpm: Double, _ sub: Subdivision) -> RenderPlan {
            RenderPlan(config: MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: sub),
                       sampleRate: sampleRate)
        }
        // Quarters have no subdivisions to speak → always "speakable" (the flag is irrelevant there).
        XCTAssertTrue(plan(240, .quarter).speaksSubdivisionSyllables)
        // Comfortable tempi → spoken.
        XCTAssertTrue(plan(60, .eighth).speaksSubdivisionSyllables)     // 0.5 s/tick
        XCTAssertTrue(plan(90, .sixteenth).speaksSubdivisionSyllables)  // ~0.167 s/tick
        // Too fast to articulate a subdivision → click it instead.
        XCTAssertFalse(plan(120, .sixteenth).speaksSubdivisionSyllables) // 0.125 s/tick
        XCTAssertFalse(plan(240, .sixteenth).speaksSubdivisionSyllables) // ~0.063 s/tick
    }

    /// The three-tier fast-tempo degrade for the sixteenth count ("1 e and a"). The physical limit is that
    /// four tokens/beat each have a floor length, so above some tempo they cannot all fit — we speak fewer
    /// rather than smear. This pins the tempos at which the tiers switch, from the measured token lengths.
    func testVoiceDetailDegradeTiers() {
        func detail(_ bpm: Double, _ sub: Subdivision) -> RenderPlan.VoiceDetail {
            RenderPlan(config: MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: sub),
                       sampleRate: sampleRate).voiceDetail
        }
        // Sixteenths: full "1 e and a" while the sixteenth interval fits a syllable (≥ 0.14 s)…
        XCTAssertEqual(detail(80, .sixteenth), .full)          // 0.1875 s/16th
        XCTAssertEqual(detail(100, .sixteenth), .full)         // 0.15 s/16th
        // …drop the "e"/"a" to clicks (speak "1 . and .") once the sixteenth no longer fits but the eighth does…
        XCTAssertEqual(detail(120, .sixteenth), .eighthsOnly)  // 0.125 s/16th, 0.25 s/8th
        XCTAssertEqual(detail(180, .sixteenth), .eighthsOnly)  // 0.083 s/16th, 0.167 s/8th
        // …and finally beats-only when even the eighth is too short.
        XCTAssertEqual(detail(240, .sixteenth), .beatsOnly)    // 0.063 s/16th, 0.125 s/8th < 0.14
        // Eighths and triplets have no middle tier: full while they fit, else beats-only.
        XCTAssertEqual(detail(120, .eighth), .full)            // 0.25 s/tick
        XCTAssertEqual(detail(240, .eighth), .beatsOnly)       // 0.125 s/tick < 0.14
        XCTAssertEqual(detail(120, .triplet), .full)           // 0.167 s/tick
        XCTAssertEqual(detail(200, .triplet), .beatsOnly)      // 0.10 s/tick < 0.14
        // Quarters never subdivide → always full (the flag is irrelevant there).
        XCTAssertEqual(detail(240, .quarter), .full)
    }

    /// In the middle (`.eighthsOnly`) tier the engine speaks the beat number and the "and" (the eighth
    /// positions) and clicks the "e"/"a" — so the beat number gets a whole eighth before the next spoken
    /// token instead of a single sixteenth, which is what stops it from being chopped mid-word.
    func testEighthsOnlyTierSpeaksBeatAndAndClicksEandA() {
        let p = RenderPlan(config: MetronomeConfiguration(bpm: 150, timeSignature: .common,
                                                          subdivision: .sixteenth),
                           sampleRate: sampleRate)
        XCTAssertEqual(p.voiceDetail, .eighthsOnly)          // 0.10 s/16th, 0.20 s/8th
        XCTAssertTrue(p.speaksSubdivision(atPosInBeat: 0))   // the beat number — always spoken
        XCTAssertFalse(p.speaksSubdivision(atPosInBeat: 1))  // "e"  → click
        XCTAssertTrue(p.speaksSubdivision(atPosInBeat: 2))   // "and" → spoken
        XCTAssertFalse(p.speaksSubdivision(atPosInBeat: 3))  // "a"  → click
    }

    /// End-to-end: in Voice mode at a fast sixteenth tempo, the subdivisions can't be spoken — but a
    /// sound (a click) must still land on every subdivision tick so the count is never lost. Whether a
    /// tick sounds spoken or clicked, the onset is on the same sample-accurate grid.
    func testFastTempoVoiceKeepsASoundOnEverySubdivisionTick() throws {
        let bpm = 200.0
        let tpb = 4                                        // sixteenth (musical fact, hard-coded)
        let framesPerTick = (60.0 / bpm / Double(tpb)) * sampleRate
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                            subdivision: .sixteenth, sound: .voice)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

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
                "fast-tempo voice: no sound on subdivision tick \(tick) (frame \(f)) — count would be lost")
            tick += 1
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8, "too few ticks checked")
    }

    // MARK: - Aggressive syllable compaction (so a fast count fits inside its tick)

    func testCompactSyllableCapsLength() {
        // 0.5 s of loud samples, capped to 0.13 s so it fits inside a fast subdivision tick.
        let long = [Float](repeating: 0.5, count: Int(0.5 * sampleRate))
        let compact = VoiceSampleFactory.compactSyllable(long, sampleRate: sampleRate, maxSeconds: 0.13)
        XCTAssertGreaterThan(compact.count, 0)
        XCTAssertLessThanOrEqual(compact.count, Int(0.13 * sampleRate) + 1)
    }

    func testCompactSyllableKeepsOnsetAtFrameZero() {
        // Leading silence then loud content: the onset must land at frame 0 so it stays on its tick.
        var s = [Float](repeating: 0, count: 200)
        s += [Float](repeating: 0.6, count: Int(0.05 * sampleRate))
        let compact = VoiceSampleFactory.compactSyllable(s, sampleRate: sampleRate)
        XCTAssertGreaterThan(abs(compact.first ?? 0), 0.05, "onset not at frame 0 after trimming")
    }

    func testCompactSyllableShortBufferPassesThrough() {
        // A syllable already under the cap keeps its samples (outer-trimmed only).
        let short: [Float] = [0.5, -0.5, 0.5, -0.5]
        XCTAssertEqual(VoiceSampleFactory.compactSyllable(short, sampleRate: sampleRate, maxSeconds: 0.13), short)
    }

    func testCompactSyllableAllSilenceIsEmpty() {
        let silent = [Float](repeating: 0, count: 1000)
        XCTAssertTrue(VoiceSampleFactory.compactSyllable(silent, sampleRate: sampleRate).isEmpty,
                      "all-silence ⇒ empty (engine clicks the tick)")
    }

    func testCompactSyllableEndFadesToAvoidAClick() {
        // The hard length cap fades out, so the truncation can't pop.
        let long = [Float](repeating: 0.5, count: Int(0.5 * sampleRate))
        let compact = VoiceSampleFactory.compactSyllable(long, sampleRate: sampleRate, maxSeconds: 0.13)
        XCTAssertLessThan(abs(compact.last ?? 1), 0.2, "capped tail should be faded toward zero")
    }
}
