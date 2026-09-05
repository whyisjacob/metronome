import XCTest
import AVFoundation
@testable import Metronome

/// Proof that the NEW voice settings actually affect the output — no dead controls.
///
///  * **Voice volume** is proven end-to-end on the real offline render path (with synthetic spoken buffers,
///    since a logic-test bundle carries no voice `.wav`): halving the volume halves the spoken amplitude,
///    and it is independent of clicks.
///  * **Voice timing** (the "skosh slow" fix) is proven on the pure `alignPerceptualOnset`, which pulls a
///    spoken word's perceptual onset toward frame 0 so the count lands on the beat.
final class VoiceSettingsRenderTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Voice volume actually scales the spoken output

    private func renderVoicePeak(volume: Double) throws -> Float {
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        // Synthetic constant-amplitude spoken buffers on the REAL render path (install AFTER prepare, which
        // resets the voice table; the rate is marked rendered so the lazy loader can't clobber them).
        let amp: Float = 0.5
        let one = [Float](repeating: amp, count: Int(0.2 * sampleRate))
        let numbers = [[Float]](repeating: one, count: 32)
        let syllables = [[Float]](repeating: one, count: VoiceSyllable.allCases.count)
        engine.installSyntheticVoiceTablesForTesting(numbers: numbers, syllables: syllables, sampleRate: sampleRate)
        engine.setVoiceVolume(volume)

        // 100 BPM quarter 4/4: one spoken number per beat, tokens far shorter than the beat (no overlap),
        // so the measured peak is exactly the buffer amplitude × the voice volume.
        let config = MetronomeConfiguration(bpm: 100, timeSignature: .common, subdivision: .quarter, sound: .voice)
        let samples = try engine.renderOffline(config: config, seconds: 2.0)
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return peak
    }

    func testVoiceVolumeScalesSpokenAmplitude() throws {
        let full = try renderVoicePeak(volume: 1.0)
        let half = try renderVoicePeak(volume: 0.5)
        XCTAssertGreaterThan(full, 0.4, "at full volume the spoken count should be ~the buffer amplitude (0.5)")
        XCTAssertEqual(half, full * 0.5, accuracy: 0.06, "half voice volume must ~halve the spoken amplitude")
    }

    func testVoiceVolumeZeroSilencesTheSpokenVoice() throws {
        let silent = try renderVoicePeak(volume: 0.0)
        XCTAssertLessThan(silent, 0.02, "voice volume 0 must silence the spoken count")
    }

    // MARK: - Voice timing (perceptual-onset alignment) — the "skosh slow" fix

    private func perceptualOnset(_ s: [Float]) -> Int {
        var pk: Float = 0
        for v in s { pk = max(pk, abs(v)) }
        return s.firstIndex(where: { abs($0) >= 0.30 * pk }) ?? 0
    }

    func testAlignPerceptualOnsetPullsTheLoudOnsetEarlierAndIsBounded() {
        let sr = sampleRate
        // A consonant-initial word: 60 ms of soft sub-perceptual lead-in (0.05), then the loud vowel (0.9).
        let leadIn = Int(0.06 * sr)
        let body = Int(0.20 * sr)
        var samples = [Float](repeating: 0.05, count: leadIn)
        samples += [Float](repeating: 0.9, count: body)

        let aligned = VoiceSampleFactory.alignPerceptualOnset(samples, sampleRate: sr, maxLeadSeconds: 0.03)

        // The perceived (loud) onset is pulled toward frame 0 — the count lands earlier, on the beat.
        XCTAssertLessThan(perceptualOnset(aligned), perceptualOnset(samples),
                          "alignment should pull the loud onset closer to frame 0")
        // …but bounded by maxLeadSeconds, so a strong consonant is never fully gutted.
        let removed = samples.count - aligned.count
        XCTAssertGreaterThan(removed, 0, "a 60 ms sub-perceptual lead-in should be trimmed")
        XCTAssertLessThanOrEqual(removed, Int(0.03 * sr) + 1, "the trim must be bounded by maxLeadSeconds")
    }

    func testAlignPerceptualOnsetIsANoOpAtZeroLead() {
        let sr = sampleRate
        var samples = [Float](repeating: 0.05, count: Int(0.06 * sr))
        samples += [Float](repeating: 0.9, count: Int(0.2 * sr))
        // Dialled to zero it is exactly the original trim-silence behaviour (the fix can be turned off).
        XCTAssertEqual(VoiceSampleFactory.alignPerceptualOnset(samples, sampleRate: sr, maxLeadSeconds: 0),
                       VoiceSampleFactory.trimSilence(samples))
    }

    func testAlignPerceptualOnsetKeepsAVowelInitialWordAlmostIntact() {
        let sr = sampleRate
        // A word already loud at the start (a vowel) has no soft lead-in → little or nothing is trimmed.
        let samples = [Float](repeating: 0.9, count: Int(0.2 * sr))
        let aligned = VoiceSampleFactory.alignPerceptualOnset(samples, sampleRate: sr, maxLeadSeconds: 0.03)
        XCTAssertEqual(aligned.count, samples.count, "a vowel-initial word should be left essentially intact")
    }
}
