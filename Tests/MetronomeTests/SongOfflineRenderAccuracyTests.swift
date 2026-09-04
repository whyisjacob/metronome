import XCTest
import AVFoundation
@testable import Metronome

/// The song-mode headless accuracy proof — the multi-tempo analogue of `OfflineRenderAccuracyTests`,
/// and just as deliberately **independent**.
///
/// It renders a whole multi-section song through `MetronomeEngine`'s real `AVAudioSourceNode` callback
/// under AVAudioEngine offline manual rendering (the same code that runs live), detects click onsets in
/// the produced PCM, and confronts them with a grid built **from first principles**, never from
/// `SongPlan`:
///
///   * A running **integer** frame cursor. Section `s` begins at `Σ_{j<s} round(totalTicks_j × fpt_j)`,
///     where `fpt_j = (60 / BPM_j) / ticksPerBeat_j × sampleRate` and `ticksPerBeat` is the subdivision's
///     musical meaning hard-coded per case (quarter 1, eighth 2, triplet 3, sixteenth 4).
///   * Click `i` of section `s` is due at `cursor_s + round(i × fpt_s)`.
///
/// Because the oracle is derived from the musical definition and the integer-cursor rule the task
/// specifies — not from the code under test — a defect in `SongPlan`/engine (an accumulating cursor, a
/// boundary rounded the wrong way, a tempo/meter/subdivision switched one tick early) makes the *audio*
/// disagree with this grid and fails the test. Assertion (C) is tight enough that a boundary misplaced
/// by even one sample fails. The oracle is never relaxed to match a broken engine.
final class SongOfflineRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Independent oracle (identical discipline to SongPlanTests, kept self-contained)

    fileprivate struct Spec {
        let name: String
        let bpm: Double
        let numerator: Int
        let denominator: Int
        let subdivision: Subdivision
        let ticksPerBeat: Int          // hard-coded musical meaning, NOT Subdivision.ticksPerBeat
        let bars: Int
        let repeatCount: Int
        let accents: [Bool]
    }

    private struct ExpectedClick {
        let frame: Int
        let section: Int
        let localTick: Int
        let accent: AccentLevel
    }

    private struct Oracle {
        let clicks: [ExpectedClick]
        let sectionStarts: [Int]
        let sectionClickCounts: [Int]
        let firstClickIndex: [Int]
        let framesPerTick: [Double]
        var totalFrames: Int { sectionStarts.last ?? 0 }
    }

    private func buildOracle(_ specs: [Spec], sampleRate: Double) -> Oracle {
        var clicks: [ExpectedClick] = []
        var starts: [Int] = []
        var counts: [Int] = []
        var firsts: [Int] = []
        var fpts: [Double] = []
        var cursor = 0
        for (s, spec) in specs.enumerated() {
            starts.append(cursor)
            firsts.append(clicks.count)

            let secondsPerBeat = 60.0 / spec.bpm
            let secondsPerTick = secondsPerBeat / Double(spec.ticksPerBeat)
            let fpt = secondsPerTick * sampleRate
            fpts.append(fpt)

            let ticksPerBar = spec.ticksPerBeat * spec.numerator
            let totalTicks = ticksPerBar * spec.bars * spec.repeatCount
            counts.append(totalTicks)

            for i in 0..<totalTicks {
                let frame = cursor + Int((Double(i) * fpt).rounded())
                let tickWithinBar = i % ticksPerBar
                let accent: AccentLevel
                if tickWithinBar % spec.ticksPerBeat == 0 {
                    let beat = tickWithinBar / spec.ticksPerBeat
                    accent = (spec.accents.indices.contains(beat) && spec.accents[beat]) ? .strong : .normal
                } else {
                    accent = .weak
                }
                clicks.append(ExpectedClick(frame: frame, section: s, localTick: i, accent: accent))
            }
            cursor += Int((Double(totalTicks) * fpt).rounded())   // round section length ONCE
        }
        starts.append(cursor)
        return Oracle(clicks: clicks, sectionStarts: starts, sectionClickCounts: counts,
                      firstClickIndex: firsts, framesPerTick: fpts)
    }

    private func makeSong(_ specs: [Spec]) -> Song {
        Song(name: "Test", sections: specs.map { spec in
            SongSection(name: spec.name,
                        tempoBPM: spec.bpm,
                        timeSignature: TimeSignature(numerator: spec.numerator,
                                                     denominator: spec.denominator),
                        subdivision: spec.subdivision,
                        accentPattern: spec.accents,
                        bars: spec.bars,
                        repeatCount: spec.repeatCount)
        })
    }

    // MARK: - The core test

    /// The task's example song: 2 bars 4/4 @120 (quarter) → 2 bars 3/4 @90 (eighth, a subdivision
    /// change) → 3 bars 7/8 @144 (quarter, an odd meter). The fastest inter-onset interval here is the
    /// eighth at 90 BPM ≈ 333 ms, far longer than the 18 ms detection guard.
    func testExampleSongOnsetsMatchIndependentGridAcrossTransitions() throws {
        let specs = [
            Spec(name: "A", bpm: 120, numerator: 4, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 1, accents: [true, false, false, false]),
            Spec(name: "B", bpm: 90, numerator: 3, denominator: 4, subdivision: .eighth,
                 ticksPerBeat: 2, bars: 2, repeatCount: 1, accents: [true, false, false]),
            Spec(name: "C", bpm: 144, numerator: 7, denominator: 8, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 3, repeatCount: 1, accents: [true, false, false, true, false, false, false]),
        ]
        try renderAndAssert(specs, label: "example song 4/4→3/4→7/8")
    }

    /// A second, harder map: a subdivision change into fast sixteenths and a section with repeats, plus
    /// three distinct tempos. Fastest interval is the sixteenth at 132 BPM ≈ 114 ms — still safe.
    func testSubdivisionAndRepeatSongMatchesIndependentGrid() throws {
        let specs = [
            Spec(name: "A", bpm: 100, numerator: 4, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 1, accents: [true, false, false, false]),
            Spec(name: "B", bpm: 132, numerator: 5, denominator: 8, subdivision: .sixteenth,
                 ticksPerBeat: 4, bars: 1, repeatCount: 2, accents: [true, false, true, false, false]),
            Spec(name: "C", bpm: 80, numerator: 6, denominator: 8, subdivision: .eighth,
                 ticksPerBeat: 2, bars: 2, repeatCount: 1, accents: [true, false, false, true, false, false]),
        ]
        try renderAndAssert(specs, label: "sixteenth + repeat song 4/4→5/8→6/8")
    }

    // MARK: - Render + confront

    private func renderAndAssert(_ specs: [Spec], label: String) throws {
        let oracle = buildOracle(specs, sampleRate: sampleRate)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOfflineSong(makeSong(specs))
        XCTAssertFalse(samples.isEmpty, "no audio rendered for \(label)")

        // 18 ms guard: longer than the longest click body (≤16 ms) so a click counts once, yet far
        // shorter than the smallest inter-onset interval in either song (≥114 ms). Derived from the
        // click length, never from the tested tempo.
        let minGap = Int(0.018 * sampleRate)
        let onsets = Self.detectOnsets(in: samples, minGap: minGap)

        // Offline manual rendering adds no hardware latency: playback begins exactly on sample 0.
        XCTAssertGreaterThan(onsets.count, 2, "too few onsets for \(label)")
        let base = onsets[0]
        XCTAssertLessThanOrEqual(base, 1, "unexpected start offset (\(base)) for \(label)")

        // (A) ONSET COUNT equals the independently expanded grid exactly. A wrong tempo/subdivision
        //     anywhere changes the click density and diverges by many.
        XCTAssertEqual(onsets.count, oracle.clicks.count,
            "onset count \(onsets.count) vs first-principles \(oracle.clicks.count) for \(label)")

        let comparable = min(onsets.count, oracle.clicks.count)
        for k in 0..<comparable {
            let e = oracle.clicks[k]
            let measured = Double(onsets[k] - base)

            // (B) Each onset sits on the independent integer grid to within a sample (absorbs float
            //     rounding only).
            XCTAssertLessThan(abs(measured - Double(e.frame)), 2.0,
                "onset \(k) off the grid for \(label): measured \(measured), grid \(e.frame)")

            // (C) ZERO CUMULATIVE DRIFT across the whole song. Deviation from the *continuous* ideal,
            //     anchored at the section's independently computed integer start, stays below one sample
            //     for EVERY click — the last section as tight as the first. At a section's first click
            //     (localTick 0) the ideal IS the integer boundary cursor, so a boundary misplaced by ≥1
            //     sample makes this reach ≥1 and FAILS.
            let idealContinuous = Double(oracle.sectionStarts[e.section])
                + Double(e.localTick) * oracle.framesPerTick[e.section]
            XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                "onset \(k) drifted for \(label): measured \(measured), ideal \(idealContinuous)")
        }

        // (D) BOUNDARY EXACTNESS — spell out the transition check the task calls for: the first click
        //     of every section after the first lands on the independent integer cursor within <1 sample.
        for s in 1..<specs.count {
            let k = oracle.firstClickIndex[s]
            guard k < comparable else { continue }
            let measured = Double(onsets[k] - base)
            XCTAssertLessThan(abs(measured - Double(oracle.sectionStarts[s])), 1.0,
                "section \(s) boundary misplaced for \(label): measured \(measured), cursor \(oracle.sectionStarts[s])")
        }

        // (E) PER-SECTION MEAN INTERVAL equals that section's ideal frames/tick within a rounding-bounded
        //     epsilon — a drift summary that would break under any systematic per-click drift.
        for s in specs.indices {
            let first = oracle.firstClickIndex[s]
            let count = oracle.sectionClickCounts[s]
            guard count >= 2, first + count - 1 < comparable else { continue }
            let measuredMean = Double(onsets[first + count - 1] - onsets[first]) / Double(count - 1)
            XCTAssertEqual(measuredMean, oracle.framesPerTick[s], accuracy: 0.5,
                "section \(s) mean interval \(measuredMean) vs ideal \(oracle.framesPerTick[s]) for \(label)")
        }

        // (F) ACCENTS survive the section switches: a strong downbeat renders louder than the next
        //     unaccented beat within the same opening section.
        if comparable >= 2 {
            func peak(at frame: Int) -> Float {
                let end = min(frame + 512, samples.count)
                var p: Float = 0
                for i in frame..<end { p = max(p, abs(samples[i])) }
                return p
            }
            XCTAssertGreaterThan(peak(at: onsets[0]), peak(at: onsets[1]),
                "accented downbeat should be louder than the next beat for \(label)")
        }
    }

    // MARK: - Onset detection (identical technique to OfflineRenderAccuracyTests; no timing knowledge)

    /// Returns the frame index of every click onset. The first frame past a silent guard whose magnitude
    /// crosses `threshold` is the onset; we then skip `minGap` frames (past the short click body, still
    /// before the next onset) to avoid double-counting. Operates purely on the rendered samples.
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
