import XCTest
import AVFoundation
@testable import Metronome

/// The headless accuracy proof — and a deliberately **independent** one.
///
/// This test never asks the engine, `RenderPlan`, or `MetronomeConfiguration` *where a click should
/// be*. It builds its own oracle from first principles and confronts the real rendered audio with it:
///
///   1. **First-principles grid.** `secondsPerBeat = 60 / BPM`; a beat is split into `ticksPerBeat`
///      equal clicks (the musical fact for the subdivision — quarter 1, eighth 2, triplet 3,
///      sixteenth 4 — written out per case, *not* read from `Subdivision.ticksPerBeat`). So click `k`
///      is due at `t = k · secondsPerBeat / ticksPerBeat`, i.e. frame `round(t · sampleRate)`.
///   2. **Real render path.** Audio is produced by `MetronomeEngine`'s `AVAudioSourceNode` callback
///      driven through AVAudioEngine **offline manual rendering** — the same code that runs live, no
///      device required, fully deterministic.
///   3. **Onset detection in the PCM.** The produced samples are scanned; the first sample past a
///      silent guard whose magnitude crosses a threshold is the onset. (Each click's first sample is
///      its peak — cosine carrier — and clicks are separated by silence here, so this is exact.)
///   4. **Assertions.** Every detected onset must land on the first-principles grid to within one
///      sample, and its deviation from the *continuous* ideal must never grow — zero cumulative drift.
///
/// Because the oracle comes from the musical definition, not from the code under test, a defect in the
/// engine's tempo/subdivision math (a wrong `60`, a wrong ticks-per-beat, an accumulating scheduler
/// instead of the closed form) makes the *audio* disagree with this grid and fails the test. The
/// continuous-deviation bound in (C) is tight enough that a drift of even ~1 sample per beat is caught
/// by the first beat boundary. The test asserts the engine's correctness; it must never be relaxed to
/// match a broken engine.
final class OfflineRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// One case. `ticksPerBeat` is the subdivision's musical meaning, hard-coded so the expected grid
    /// is derived independently of the production `Subdivision.ticksPerBeat` value under test.
    private struct Case {
        let bpm: Double
        let numerator: Int
        let denominator: Int
        let subdivision: Subdivision
        let ticksPerBeat: Int
        var label: String { "\(bpm) BPM \(numerator)/\(denominator) \(subdivision.displayName)" }
    }

    func testOnsetsMatchFirstPrinciplesGridWithZeroDrift() throws {
        // ≥3 tempos (40 / 120 / 208) and several time-signature × subdivision combinations, including
        // odd/compound meters and every subdivision (32nds included). The fastest inter-onset interval
        // here is 208 BPM sixteenths ≈ 72 ms, comfortably longer than the 18 ms detection guard below;
        // the 100 BPM 32nds ≈ 75 ms are next-fastest, still well clear of the guard.
        let cases: [Case] = [
            Case(bpm: 40,  numerator: 4, denominator: 4, subdivision: .quarter,      ticksPerBeat: 1),
            Case(bpm: 120, numerator: 4, denominator: 4, subdivision: .quarter,      ticksPerBeat: 1),
            Case(bpm: 208, numerator: 4, denominator: 4, subdivision: .quarter,      ticksPerBeat: 1),
            Case(bpm: 120, numerator: 3, denominator: 4, subdivision: .eighth,       ticksPerBeat: 2),
            Case(bpm: 90,  numerator: 6, denominator: 8, subdivision: .sixteenth,    ticksPerBeat: 4),
            Case(bpm: 144, numerator: 7, denominator: 8, subdivision: .triplet,      ticksPerBeat: 3),
            Case(bpm: 208, numerator: 4, denominator: 4, subdivision: .sixteenth,    ticksPerBeat: 4),
            // 32nd note (ticksPerBeat = 8) — the new subdivision, held to the same independent grid.
            Case(bpm: 100, numerator: 4, denominator: 4, subdivision: .thirtysecond, ticksPerBeat: 8),
            Case(bpm: 60,  numerator: 3, denominator: 4, subdivision: .thirtysecond, ticksPerBeat: 8),
        ]

        let seconds = 20.0

        for c in cases {
            // ---- Independent oracle: the ideal grid, from first principles only ----
            // No engine / RenderPlan / MetronomeConfiguration timing is consulted here.
            let secondsPerBeat = 60.0 / c.bpm
            let secondsPerTick = secondsPerBeat / Double(c.ticksPerBeat)
            let framesPerTick  = secondsPerTick * sampleRate           // continuous; may be fractional

            // ---- Render the REAL path, offline ----
            let config = MetronomeConfiguration(
                bpm: c.bpm,
                timeSignature: TimeSignature(numerator: c.numerator, denominator: c.denominator),
                subdivision: c.subdivision
            )
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let samples = try engine.renderOffline(config: config, seconds: seconds)
            XCTAssertFalse(samples.isEmpty, "no audio rendered for \(c.label)")

            // ---- Detect onsets by scanning the produced PCM ----
            // 18 ms guard: longer than the longest click body (≤16 ms) so a click is counted once, yet
            // far shorter than the smallest inter-onset interval among these cases (≈72 ms), so no real
            // onset is skipped. It is derived from the click length, never from the tested tempo.
            let minGap = Int(0.018 * sampleRate)
            let onsets = Self.detectOnsets(in: samples, minGap: minGap)
            XCTAssertGreaterThan(onsets.count, 2, "too few onsets for \(c.label)")

            // Offline manual rendering adds no hardware latency: playback begins exactly on sample 0.
            let base = onsets[0]
            XCTAssertLessThanOrEqual(base, 1, "unexpected start offset (\(base)) for \(c.label)")

            // (A) ONSET COUNT matches the first-principles grid (±1 at the render boundary). A wrong
            //     tempo or subdivision changes the click density and makes this diverge by many.
            let totalFrames = Int((seconds * sampleRate).rounded())
            var expectedCount = 0
            while Int((Double(expectedCount) * framesPerTick).rounded()) < totalFrames {
                expectedCount += 1
            }
            XCTAssertLessThanOrEqual(abs(onsets.count - expectedCount), 1,
                "onset count \(onsets.count) vs first-principles \(expectedCount) for \(c.label)")

            let comparable = min(onsets.count, expectedCount)
            XCTAssertGreaterThan(comparable, 2, "need several onsets to prove drift for \(c.label)")

            for k in 0..<comparable {
                let idealContinuous = Double(k) * framesPerTick        // t · sr, closed form (no drift)
                let idealFrame      = idealContinuous.rounded()        // nearest sample on the grid
                let measured        = Double(onsets[k] - base)         // anchored → isolates drift

                // (B) Each onset sits on the integer grid to within one sample (absorbs float rounding
                //     only). A constant offset is divided out by anchoring at the first onset.
                XCTAssertLessThan(abs(measured - idealFrame), 2.0,
                    "onset \(k) off the grid for \(c.label): measured \(measured), ideal \(idealFrame)")

                // (C) ZERO CUMULATIVE DRIFT — the core proof. Deviation from the *continuous* ideal
                //     stays below a sample for EVERY click, the last as tight as the first. A drift of
                //     ~1 sample per beat would reach ≥1 sample by the first beat boundary and fail here.
                XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                    "onset \(k) drifted for \(c.label): measured \(measured), ideal \(idealContinuous)")
            }

            // (D) Mean measured inter-onset interval equals the ideal within a rounding-bounded epsilon
            //     — a global drift summary. With N clicks the rounding error shrinks as 0.5/N, so any
            //     systematic per-click drift (which does not shrink) would break this.
            let lastK = comparable - 1
            let measuredMean = Double(onsets[lastK] - onsets[0]) / Double(lastK)
            XCTAssertEqual(measuredMean, framesPerTick, accuracy: 0.5,
                "mean interval \(measuredMean) vs ideal \(framesPerTick) for \(c.label)")
        }
    }

    /// Custom **odd** numerators (5 and 11) — the meters the widened numerator range exists for — must
    /// render drift-free AND accent beat 1 of every bar by default. The oracle is first-principles only:
    /// onsets are `round(k · 60/BPM · sampleRate)` (quarter = 1 tick/beat, hard-coded here, not read from
    /// the engine); the numerator's job is proven separately by checking the accented (louder) onsets land
    /// on every numerator-th beat. This is the same independent discipline as the grid test above.
    func testOddCustomNumeratorsAreDriftFreeWithDefaultDownbeatAccent() throws {
        for numerator in [5, 11] {
            let bpm = 132.0
            let secondsPerBeat = 60.0 / bpm            // quarter note → 1 tick/beat
            let framesPerBeat  = secondsPerBeat * sampleRate

            let config = MetronomeConfiguration(
                bpm: bpm,
                timeSignature: TimeSignature(numerator: numerator, denominator: 4),
                subdivision: .quarter
            )
            // The arbitrary numerator is preserved (it was capped at 16 before) and the default accent
            // pattern marks only beat 1 — the fact the engine must honour for an odd meter.
            XCTAssertEqual(config.timeSignature.numerator, numerator, "numerator \(numerator) must not be clamped")
            XCTAssertEqual(config.accents.first, true)
            XCTAssertFalse(config.accents.dropFirst().contains(true),
                           "default pattern must accent only beat 1 for \(numerator)/4")

            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let bars = 3
            let seconds = Double(bars * numerator) * secondsPerBeat + 0.25
            let samples = try engine.renderOffline(config: config, seconds: seconds)

            let minGap = Int(0.018 * sampleRate)
            let onsets = Self.detectOnsets(in: samples, minGap: minGap)
            XCTAssertGreaterThanOrEqual(onsets.count, bars * numerator,
                "expected ≥ \(bars * numerator) beats for \(numerator)/4, got \(onsets.count)")

            let base = onsets[0]
            XCTAssertLessThanOrEqual(base, 1, "playback must begin on sample 0 for \(numerator)/4")

            // (A) ZERO CUMULATIVE DRIFT on the independent quarter-note grid — the last beat as tight as
            //     the first. (The numerator does not affect onset timing, only which onsets are accented.)
            let comparable = min(onsets.count, bars * numerator)
            for k in 0..<comparable {
                let idealContinuous = Double(k) * framesPerBeat
                let measured = Double(onsets[k] - base)
                XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                    "onset \(k) drifted for \(numerator)/4: measured \(measured), ideal \(idealContinuous)")
            }

            // (B) The DEFAULT accent lands on beat 1 of every bar for the arbitrary numerator: the onset
            //     at each multiple of `numerator` is louder than the following (unaccented) beat. This
            //     exercises the engine's accent math (beat = tick % numerator) on a non-preset meter.
            func peak(at frame: Int) -> Float {
                let end = min(frame + 512, samples.count)
                var p: Float = 0
                for i in frame..<end { p = max(p, abs(samples[i])) }
                return p
            }
            for bar in 0..<bars {
                let downbeat = bar * numerator
                let nextBeat = downbeat + 1
                guard nextBeat < comparable else { break }
                XCTAssertGreaterThan(peak(at: onsets[downbeat]), peak(at: onsets[nextBeat]),
                    "bar \(bar) downbeat must be accented (louder) for \(numerator)/4")
            }
        }
    }

    /// Compound meters (6/8, 9/8, 12/8) render drift-free on the same independent grid AND accent the
    /// dotted-quarter **group heads** (beats 1, 4, 7, 10) by default. The oracle is first-principles only:
    /// with the base (quarter) subdivision each meter pulses `numerator` times per bar, so onset `k` is
    /// `round(k · 60/BPM · sampleRate)` (1 tick/beat hard-coded, not read from the engine). The grouping's
    /// job is proven by checking every group head renders louder than the inner pulse that follows it.
    func testCompoundMetersGroupHeadAccentsAreDriftFree() throws {
        for numerator in [6, 9, 12] {
            let bpm = 132.0
            let secondsPerBeat = 60.0 / bpm            // one eighth-pulse per beat tick
            let framesPerBeat  = secondsPerBeat * sampleRate

            let config = MetronomeConfiguration(
                bpm: bpm,
                timeSignature: TimeSignature(numerator: numerator, denominator: 8),
                subdivision: .quarter
            )
            // The default accent pattern must mark exactly the group heads (every third beat).
            var expectedAccents = [Bool](repeating: false, count: numerator)
            for i in stride(from: 0, to: numerator, by: 3) { expectedAccents[i] = true }
            XCTAssertEqual(config.accents, expectedAccents,
                           "compound \(numerator)/8 must default to group-head accents")

            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let bars = 2
            let seconds = Double(bars * numerator) * secondsPerBeat + 0.25
            let samples = try engine.renderOffline(config: config, seconds: seconds)

            let minGap = Int(0.018 * sampleRate)
            let onsets = Self.detectOnsets(in: samples, minGap: minGap)
            XCTAssertGreaterThanOrEqual(onsets.count, bars * numerator,
                "expected ≥ \(bars * numerator) pulses for \(numerator)/8, got \(onsets.count)")

            let base = onsets[0]
            XCTAssertLessThanOrEqual(base, 1, "playback must begin on sample 0 for \(numerator)/8")

            // (A) ZERO CUMULATIVE DRIFT on the independent pulse grid.
            let comparable = min(onsets.count, bars * numerator)
            for k in 0..<comparable {
                let idealContinuous = Double(k) * framesPerBeat
                let measured = Double(onsets[k] - base)
                XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                    "compound \(numerator)/8 onset \(k) drifted: measured \(measured), ideal \(idealContinuous)")
            }

            // (B) GROUP HEADS are accented: each of beats 0, 3, 6, 9 renders louder than the next pulse.
            func peak(at frame: Int) -> Float {
                let end = min(frame + 512, samples.count)
                var p: Float = 0
                for i in frame..<end { p = max(p, abs(samples[i])) }
                return p
            }
            for head in stride(from: 0, to: comparable - 1, by: 3) {
                XCTAssertGreaterThan(peak(at: onsets[head]), peak(at: onsets[head + 1]),
                    "compound \(numerator)/8 group head at beat \(head) must be accented (louder)")
            }
        }
    }

    /// Subdivision changes click density exactly as first principles predict (audio-level count).
    /// Expected counts are hand-derived, not taken from the engine.
    func testSubdivisionOnsetCounts() throws {
        func onsetCount(_ sub: Subdivision) throws -> Int {
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }
            let config = MetronomeConfiguration(bpm: 60, timeSignature: .common, subdivision: sub)
            let samples = try engine.renderOffline(config: config, seconds: 4.0)
            return Self.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate)).count
        }
        // 60 BPM over 4 s (a beat every 1 s): quarter → clicks at 0,1,2,3 s = 4; eighth → 8;
        // sixteenth → 16; 32nd → 8 per beat × 4 = 32. (The click at exactly 4 s is past the render
        // window and not produced.)
        XCTAssertEqual(try onsetCount(.quarter), 4)
        XCTAssertEqual(try onsetCount(.eighth), 8)
        XCTAssertEqual(try onsetCount(.sixteenth), 16)
        XCTAssertEqual(try onsetCount(.thirtysecond), 32)
    }

    /// The accented downbeat renders louder than an unaccented beat (audio-level check).
    func testAccentedDownbeatIsLouder() throws {
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let config = MetronomeConfiguration(bpm: 100, timeSignature: .common, subdivision: .quarter)
        let samples = try engine.renderOffline(config: config, seconds: 4.0)
        let onsets = Self.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThanOrEqual(onsets.count, 2)

        func peak(at frame: Int) -> Float {
            let end = min(frame + 512, samples.count)
            var p: Float = 0
            for i in frame..<end { p = max(p, abs(samples[i])) }
            return p
        }
        XCTAssertGreaterThan(peak(at: onsets[0]), peak(at: onsets[1]),
            "the accented downbeat should be louder than an unaccented beat")
    }

    // MARK: - Onset detection

    /// Returns the frame index of every click onset. The first frame whose magnitude reaches
    /// `threshold` after a silent guard is the onset; we then skip `minGap` frames (past the short
    /// click body, still before the next onset) to avoid double-counting. Operates purely on the
    /// rendered samples — it has no knowledge of the timing grid.
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
