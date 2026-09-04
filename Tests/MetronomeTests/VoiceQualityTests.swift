import XCTest
import AVFoundation
@testable import Metronome

/// Tests for the Voice-quality work (feature 2): the pure, headless-testable pieces (trim-both-ends,
/// higher-quality voice ranking, the fast-tempo speak-vs-click threshold) plus an end-to-end proof that
/// at a fast tempo the count is never lost — a sound still lands on every subdivision tick.
///
/// The actual rate/pitch/voice *sound* can't be asserted in a headless renderer (there may be no speech
/// synthesis), so those are exercised for well-formedness; the decisions that govern them are unit-tested
/// directly here.
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

    // MARK: - Prefer an enhanced / premium, English voice

    func testVoiceRankingPrefersHigherQualityThenPreferredLocale() {
        typealias C = VoiceSampleFactory.VoiceCandidate

        // Quality dominates: the premium en-GB voice beats an enhanced/default en-US one.
        let byQuality = [C(identifier: "a", language: "en-US", qualityRank: 1),
                         C(identifier: "b", language: "en-US", qualityRank: 2),
                         C(identifier: "c", language: "en-GB", qualityRank: 3)]
        XCTAssertEqual(VoiceSampleFactory.rankBestVoice(byQuality)?.identifier, "c")

        // Same quality ⇒ the more-preferred locale (en-US) wins.
        let byLocale = [C(identifier: "x", language: "en-GB", qualityRank: 2),
                        C(identifier: "y", language: "en-US", qualityRank: 2)]
        XCTAssertEqual(VoiceSampleFactory.rankBestVoice(byLocale)?.identifier, "y")

        // English is strongly preferred even over a higher-quality non-English voice.
        let mixed = [C(identifier: "p", language: "en-AU", qualityRank: 1),
                     C(identifier: "q", language: "de-DE", qualityRank: 3)]
        XCTAssertEqual(VoiceSampleFactory.rankBestVoice(mixed)?.identifier, "p")

        // No English at all ⇒ fall back to the best available.
        let noEnglish = [C(identifier: "m", language: "de-DE", qualityRank: 1),
                         C(identifier: "n", language: "fr-FR", qualityRank: 3)]
        XCTAssertEqual(VoiceSampleFactory.rankBestVoice(noEnglish)?.identifier, "n")

        XCTAssertNil(VoiceSampleFactory.rankBestVoice([]), "no candidates ⇒ nil (caller falls back)")
    }

    func testLanguageRank() {
        let pref = ["en-US", "en-GB", "en"]
        XCTAssertEqual(VoiceSampleFactory.languageRank("en-US", pref), 0)
        XCTAssertEqual(VoiceSampleFactory.languageRank("en-GB", pref), 1)
        XCTAssertEqual(VoiceSampleFactory.languageRank("en-AU", pref), 2)   // matches the "en" catch-all
        XCTAssertEqual(VoiceSampleFactory.languageRank("EN-us", pref), 0)   // case-insensitive
        XCTAssertEqual(VoiceSampleFactory.languageRank("fr-FR", pref), 3)   // no match ⇒ count
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
