import XCTest
import AVFoundation
@testable import Metronome

/// Proof that a configuration change **during playback** (dragging the BPM slider, or changing meter /
/// subdivision live) takes effect promptly and cleanly — the fix for the "live changes don't reliably
/// apply" bug.
///
/// The engine renders the real live `update(_:)` path offline (`renderOfflineChanging`), switching config
/// partway through, and this test confronts the produced audio with a **first-principles** oracle it
/// builds itself — never asking the engine where a click should be:
///
///   * inter-onset intervals BEFORE the change equal the old tempo's `60/BPM/ticksPerBeat · sampleRate`,
///   * intervals AFTER the change equal the *new* tempo's, the last as tight as the first (no drift),
///   * the largest gap anywhere never exceeds the slower of the two intervals — the assertion that fails
///     on the old bug (decreasing the tempo pushed the next onset far into the future → a long silence),
///   * no two onsets are closer than the faster interval — no double-trigger at the switch.
///
/// `ticksPerBeat` is the subdivision's musical meaning, hard-coded per scenario, so the oracle is
/// independent of `Subdivision.ticksPerBeat` under test.
final class LiveChangeAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    private struct Scenario {
        let label: String
        let first: MetronomeConfiguration
        let second: MetronomeConfiguration
        /// First-principles frames-per-tick before/after the change (hard-coded, not from the engine).
        let interval1: Double
        let interval2: Double
    }

    /// A tempo **decrease** — the case the old code broke most visibly (the click went silent for a long
    /// stretch after the tempo dropped). 120 → 60 BPM, 4/4 quarter.
    func testTempoDecreaseAppliesLiveWithoutDroppingClicks() throws {
        try assertLiveChange(Scenario(
            label: "tempo 120→60 (decrease)",
            first:  MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter),
            second: MetronomeConfiguration(bpm: 60,  timeSignature: .common, subdivision: .quarter),
            interval1: (60.0 / 120.0) * sampleRate,   // 22 050
            interval2: (60.0 / 60.0)  * sampleRate))  // 44 100
    }

    /// A tempo **increase** applies live and re-spaces immediately. 60 → 180 BPM, 4/4 quarter.
    func testTempoIncreaseAppliesLive() throws {
        try assertLiveChange(Scenario(
            label: "tempo 60→180 (increase)",
            first:  MetronomeConfiguration(bpm: 60,  timeSignature: .common, subdivision: .quarter),
            second: MetronomeConfiguration(bpm: 180, timeSignature: .common, subdivision: .quarter),
            interval1: (60.0 / 60.0)  * sampleRate,   // 44 100
            interval2: (60.0 / 180.0) * sampleRate))  // 14 700
    }

    /// A **subdivision** change (structural) rebuilds the grid at the next safe boundary and denser
    /// clicks begin — with no gap or double-trigger. 120 BPM 4/4, quarter → eighth.
    func testSubdivisionChangeAppliesLive() throws {
        try assertLiveChange(Scenario(
            label: "subdivision quarter→eighth",
            first:  MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter),
            second: MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth),
            interval1: (60.0 / 120.0)       * sampleRate,   // 22 050 (quarter)
            interval2: (60.0 / 120.0 / 2.0) * sampleRate))  // 11 025 (eighth)
    }

    // MARK: - Render + confront

    private func assertLiveChange(_ sc: Scenario,
                                  changeAtSeconds: Double = 3.0,
                                  totalSeconds: Double = 9.0) throws {
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let (samples, changeFrame) = try engine.renderOfflineChanging(
            from: sc.first, to: sc.second,
            changeAtSeconds: changeAtSeconds, totalSeconds: totalSeconds)
        XCTAssertFalse(samples.isEmpty, "no audio rendered for \(sc.label)")

        let minGap = Int(0.018 * sampleRate)
        let onsets = Self.detectOnsets(in: samples, minGap: minGap)
        XCTAssertGreaterThan(onsets.count, 4, "too few onsets for \(sc.label)")
        XCTAssertLessThanOrEqual(onsets[0], 1, "playback must begin on sample 0 for \(sc.label)")

        var intervals: [Int] = []
        for k in 1..<onsets.count { intervals.append(onsets[k] - onsets[k - 1]) }

        let tol = 4.0
        let boundedMax = max(sc.interval1, sc.interval2)
        let boundedMin = min(sc.interval1, sc.interval2)

        // (1) NO DROPPED/SILENT SPAN: the largest inter-onset gap never exceeds the slower interval. The
        //     pre-fix bug pushed the next onset many intervals into the future on a tempo decrease, so
        //     this is the assertion that fails on the bug and passes on the fix.
        let maxInterval = Double(intervals.max() ?? 0)
        XCTAssertLessThanOrEqual(maxInterval, boundedMax + tol,
            "\(sc.label): max gap \(maxInterval) exceeds the slower interval \(boundedMax) — a dropped/late click")

        // (2) NO DOUBLE-TRIGGER at the switch: nothing closer than the faster interval.
        let minInterval = Double(intervals.min() ?? 0)
        XCTAssertGreaterThanOrEqual(minInterval, boundedMin - tol,
            "\(sc.label): min gap \(minInterval) below the faster interval \(boundedMin) — a double-trigger at the switch")

        // (3) NEW TEMPO IN EFFECT + DRIFT-FREE AFTER THE CHANGE: every interval that starts at least one
        //     new interval past the change equals the new first-principles interval — constant spacing,
        //     the last as tight as the first (drift would make later intervals diverge).
        let tailFrom = Double(changeFrame) + sc.interval2
        var tailCount = 0
        for k in 1..<onsets.count where Double(onsets[k - 1]) >= tailFrom {
            XCTAssertEqual(Double(onsets[k] - onsets[k - 1]), sc.interval2, accuracy: 2.0,
                "\(sc.label): post-change interval \(onsets[k] - onsets[k - 1]) ≠ new ideal \(sc.interval2)")
            tailCount += 1
        }
        XCTAssertGreaterThan(tailCount, 2, "\(sc.label): too few post-change intervals to prove the new tempo")

        // (4) OLD TEMPO WAS IN EFFECT BEFORE THE CHANGE: intervals fully before the change equal interval1.
        var headCount = 0
        for k in 1..<onsets.count where Double(onsets[k]) <= Double(changeFrame) - sc.interval1 {
            XCTAssertEqual(Double(onsets[k] - onsets[k - 1]), sc.interval1, accuracy: 2.0,
                "\(sc.label): pre-change interval \(onsets[k] - onsets[k - 1]) ≠ old ideal \(sc.interval1)")
            headCount += 1
        }
        XCTAssertGreaterThan(headCount, 1, "\(sc.label): too few pre-change intervals")
    }

    // MARK: - Onset detection (same technique as the other accuracy tests; no timing knowledge)

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
