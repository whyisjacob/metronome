import XCTest
import AVFoundation
@testable import Metronome

/// The headless accuracy proof. It drives the REAL render path (`MetronomeEngine`'s
/// `AVAudioSourceNode` callback) through AVAudioEngine's **offline manual-rendering** mode, then
/// scans the produced samples and asserts every click onset lands on the ideal sample grid with zero
/// cumulative drift — no device required, fully deterministic.
///
/// Onset detection is exact because each click's first sample is its peak (cosine carrier) and clicks
/// are separated by silence at the tested tempos, so the first sample ≥ threshold after a guard gap
/// is exactly the onset frame.
final class OfflineRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testOnsetsMatchIdealGridWithZeroDrift() throws {
        let cases: [(bpm: Double, num: Int, den: Int, sub: Subdivision)] = [
            (120, 4, 4, .quarter),
            (90,  3, 4, .eighth),
            (200, 5, 8, .sixteenth),
            (144, 7, 8, .triplet),
            (30,  4, 4, .quarter),
            (300, 4, 4, .quarter),
        ]

        for c in cases {
            let config = MetronomeConfiguration(
                bpm: c.bpm,
                timeSignature: TimeSignature(numerator: c.num, denominator: c.den),
                subdivision: c.sub
            )

            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let samples = try engine.renderOffline(config: config, seconds: 30.0)
            XCTAssertFalse(samples.isEmpty, "no audio rendered for \(c)")

            let minGap = Int(0.02 * sampleRate)   // 20 ms guard (< any tested inter-onset interval)
            let onsets = Self.detectOnsets(in: samples, minGap: minGap)
            XCTAssertGreaterThan(onsets.count, 1, "too few onsets for \(c)")

            let framesPerTick = config.secondsPerTick * sampleRate

            // (1) Each onset equals the closed-form ideal frame (within < 1 sample ⇒ exactly equal).
            for (k, onset) in onsets.enumerated() {
                let ideal = Int((Double(k) * framesPerTick).rounded())
                XCTAssertLessThan(abs(onset - ideal), 1,
                    "onset \(k) off grid for \(c): got \(onset), ideal \(ideal)")
            }

            // (2) Zero end-to-end drift: the final onset sits exactly on its ideal frame.
            let lastK = onsets.count - 1
            let idealLast = Int((Double(lastK) * framesPerTick).rounded())
            XCTAssertEqual(onsets[lastK], idealLast, "cumulative drift detected for \(c)")

            // (3) Deviation from the *continuous* ideal grid stays < 1 sample for every onset —
            //     i.e. rounding never accumulates.
            for (k, onset) in onsets.enumerated() {
                let idealContinuous = Double(k) * framesPerTick
                XCTAssertLessThan(abs(Double(onset) - idealContinuous), 1.0,
                    "onset \(k) drifted from the continuous grid for \(c)")
            }

            // (4) Mean measured interval equals the ideal within a rounding-bounded epsilon.
            let measuredMean = Double(onsets[lastK] - onsets[0]) / Double(lastK)
            XCTAssertEqual(measuredMean, framesPerTick, accuracy: 0.5,
                "mean interval wrong for \(c)")
        }
    }

    /// Subdivision changes the click density exactly as expected (engine-level cross-check).
    func testSubdivisionOnsetCounts() throws {
        func onsetCount(_ sub: Subdivision) throws -> Int {
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }
            let config = MetronomeConfiguration(bpm: 60, timeSignature: .common, subdivision: sub)
            let samples = try engine.renderOffline(config: config, seconds: 4.0)
            return Self.detectOnsets(in: samples, minGap: Int(0.02 * sampleRate)).count
        }
        // 60 BPM over 4 s: quarter → 4 ticks (t=0,1,2,3s), eighth → 8, sixteenth → 16.
        XCTAssertEqual(try onsetCount(.quarter), 4)
        XCTAssertEqual(try onsetCount(.eighth), 8)
        XCTAssertEqual(try onsetCount(.sixteenth), 16)
    }

    /// The accented downbeat renders louder than an unaccented beat.
    func testAccentedDownbeatIsLouder() throws {
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let config = MetronomeConfiguration(bpm: 100, timeSignature: .common, subdivision: .quarter)
        let samples = try engine.renderOffline(config: config, seconds: 4.0)
        let onsets = Self.detectOnsets(in: samples, minGap: Int(0.02 * sampleRate))
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
    /// click body, still before the next onset) to avoid double-counting.
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
