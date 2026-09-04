import XCTest
import AVFoundation
@testable import Metronome

/// The **independent** swing/shuffle accuracy proof.
///
/// Like `OfflineRenderAccuracyTests`, this never asks the engine, `RenderPlan`, or `SwingGrid` *where* a
/// swung click should land. It builds its own oracle from the musical definition of swing and confronts
/// the real rendered audio with it:
///
///   * `secondsPerBeat = 60 / BPM`; `framesPerBeat = secondsPerBeat · sampleRate` — first principles.
///   * A subdivision splits the beat into `ticksPerBeat` equal parts. Swing pairs adjacent ticks; the
///     **off** member of each pair (odd position within the beat) is delayed from **½ to ⅔ of the pair**
///     as swing runs 0 → 1, i.e. its fraction of the beat is `pairStart + (0.5 + swing/6)·pairLength`.
///     The **on** members (even positions — the main beats, and for sixteenths the "and" pulse) never
///     move. This formula is written out here from the definition, NOT read from the code under test.
///   * The real audio is produced through `MetronomeEngine`'s offline manual rendering — the same path
///     that runs live — and onsets are detected by scanning the PCM.
///
/// The proof is deliberately triple: (1) every onset lands on the independently-computed swung grid with
/// zero cumulative drift; (2) the main-beat onsets are byte-identical to the *straight* grid (swing moves
/// only off-beats); and (3) the **measured** swing ratio — taken straight from three rendered onsets,
/// with no oracle at all — equals the first-principles `0.5 + swing/6` (⅔ at full swing). A wrong ratio, a
/// drifting scheduler, or moving the main beats each fails a distinct assertion, so the test cannot pass
/// tautologically.
final class SwingAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// Independent oracle: the continuous ideal frame of tick `k`, from the swing definition only.
    private func expectedFrame(tick k: Int, ticksPerBeat tpb: Int, swing: Double,
                               framesPerBeat: Double) -> Double {
        let beat = k / tpb
        let pos = k % tpb
        let fraction: Double
        if pos % 2 == 0 {
            fraction = Double(pos) / Double(tpb)                    // on-member: straight, never displaced
        } else {
            let pairStart = Double(pos - 1) / Double(tpb)
            let pairLength = 2.0 / Double(tpb)
            fraction = pairStart + (0.5 + swing / 6.0) * pairLength // off-member: ½ → ⅔ of the pair
        }
        return (Double(beat) + fraction) * framesPerBeat
    }

    func testSwungEighthsMatchIndependentGridWithZeroDriftAndCorrectRatio() throws {
        for swing in [0.5, 1.0] {
            try assertSwing(subdivision: .eighth, ticksPerBeat: 2, bpm: 100, swing: swing, seconds: 10)
        }
    }

    func testSwungSixteenthsMatchIndependentGridAndKeepOnPulsesFixed() throws {
        for swing in [0.5, 1.0] {
            try assertSwing(subdivision: .sixteenth, ticksPerBeat: 4, bpm: 100, swing: swing, seconds: 8)
        }
    }

    /// Renders a swung subdivision and confronts the audio with the independent oracle.
    private func assertSwing(subdivision: Subdivision, ticksPerBeat tpb: Int,
                             bpm: Double, swing: Double, seconds: Double) throws {
        let label = "\(subdivision.displayName) swing \(Int(swing * 100))% @ \(bpm) BPM"

        // ---- Independent oracle constants (no engine consulted) ----
        let framesPerBeat = (60.0 / bpm) * sampleRate

        // ---- Real render path, offline ----
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                            subdivision: subdivision, swing: swing)
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        let samples = try engine.renderOffline(config: config, seconds: seconds)
        XCTAssertFalse(samples.isEmpty, "no audio for \(label)")

        let onsets = Self.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThan(onsets.count, 6, "too few onsets for \(label)")
        let base = onsets[0]
        XCTAssertLessThanOrEqual(base, 1, "playback must begin on sample 0 for \(label)")

        // (A) COUNT matches the independently-computed swung grid over the render window (±1 at boundary).
        let totalFrames = Int((seconds * sampleRate).rounded())
        var expectedCount = 0
        while Int(expectedFrame(tick: expectedCount, ticksPerBeat: tpb, swing: swing,
                                framesPerBeat: framesPerBeat).rounded()) < totalFrames {
            expectedCount += 1
        }
        XCTAssertLessThanOrEqual(abs(onsets.count - expectedCount), 1,
            "onset count \(onsets.count) vs first-principles \(expectedCount) for \(label)")

        let comparable = min(onsets.count, expectedCount)
        for k in 0..<comparable {
            let idealContinuous = expectedFrame(tick: k, ticksPerBeat: tpb, swing: swing,
                                                framesPerBeat: framesPerBeat)
            let measured = Double(onsets[k] - base)
            // (B) On the swung grid to within a sample, AND (C) zero cumulative drift — the last onset as
            //     tight as the first (a drift of ~1 sample/beat would break this by the first beat).
            XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                "onset \(k) off the swung grid / drifted for \(label): measured \(measured), ideal \(idealContinuous)")

            // (D) MAIN BEATS (and the sixteenth "and" — every even position) are UNMOVED: identical to the
            //     straight grid `round(k · framesPerBeat / tpb)`. This is the "only off-beats move" clause.
            if k % 2 == 0 {
                let straight = (Double(k) / Double(tpb)) * framesPerBeat
                XCTAssertLessThan(abs(measured - straight), 1.0,
                    "on-pulse \(k) must not move under swing for \(label): measured \(measured), straight \(straight)")
            }
        }

        // (E) MEASURED SWING RATIO — the direct, oracle-free proof. For each pair, take three rendered
        //     onsets (pair start, off member, pair end) and check the off member sits at (0.5 + swing/6)
        //     of the pair. At full swing that is ⅔ — the triplet position. Done for every pair, so a
        //     drifting ratio (correct at first, wrong later) is also caught.
        let target = 0.5 + swing / 6.0
        var pairsChecked = 0
        var pairStartTick = 0
        while pairStartTick + 2 < comparable {
            // A pair is [even, even+1, even+2] where even is an on-member (pair start).
            if pairStartTick % 2 == 0 {
                let a = Double(onsets[pairStartTick])
                let b = Double(onsets[pairStartTick + 1])
                let c = Double(onsets[pairStartTick + 2])
                let ratio = (b - a) / (c - a)
                XCTAssertEqual(ratio, target, accuracy: 0.01,
                    "\(label): measured swing ratio \(ratio) ≠ first-principles \(target) at pair starting tick \(pairStartTick)")
                pairsChecked += 1
            }
            pairStartTick += 2
        }
        XCTAssertGreaterThan(pairsChecked, 3, "\(label): too few swing pairs measured to prove the ratio")
    }

    // MARK: - Onset detection (identical technique to the other accuracy tests; no timing knowledge)

    static func detectOnsets(in samples: [Float], minGap: Int, threshold: Float = 0.05) -> [Int] {
        var onsets: [Int] = []
        var i = 0
        let n = samples.count
        while i < n {
            if abs(samples[i]) >= threshold {
                onsets.append(i)
                i += max(minGap, 1)
            } else {
                i += 1
            }
        }
        return onsets
    }
}
