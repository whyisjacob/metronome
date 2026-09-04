import XCTest
import AVFoundation
@testable import Metronome

/// Idiomatic rhythm cells (dotted-8th+16th, gallop, reverse gallop) proven at the **audio** level, with
/// the sounding pattern hard-coded here rather than read from `RhythmCell` — so a defect in the cell's
/// definition or in the engine's per-tick muting makes the rendered audio disagree with this oracle and
/// fails the test (it cannot pass tautologically).
///
/// A cell must:
///   * sound **exactly** the sixteenth sub-positions of its figure and silence the rest,
///   * leave onset **timing** untouched (every sounding click stays on the sample-accurate sixteenth grid,
///     `round(k · 60/BPM/4 · sampleRate)`), and
///   * keep the beat's accent on position 0 (the cell downbeat is louder than its inner sixteenths).
final class RhythmCellTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// The sounding sixteenth positions (0…3) of each cell — the musical fact, hard-coded independently of
    /// `RhythmCell.soundingPositions`.
    private let expectations: [(cell: RhythmCell, sounding: Set<Int>)] = [
        (.dottedEighthSixteenth, [0, 3]),
        (.gallop,                [0, 2, 3]),
        (.reverseGallop,         [0, 1, 3]),
    ]

    func testCellsSoundExactlyTheirPatternOnTheSixteenthGrid() throws {
        let bpm = 90.0                              // 90 BPM sixteenth = 7 350 frames/tick, exactly
        let framesPer16 = (60.0 / bpm / 4.0) * sampleRate
        let seconds = 8.0

        for (cell, sounding) in expectations {
            let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                                subdivision: .sixteenth, cell: cell)
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: sampleRate)
            defer { engine.teardownOfflineRendering() }

            let samples = try engine.renderOffline(config: config, seconds: seconds)
            let onsets = Self.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
            XCTAssertGreaterThan(onsets.count, sounding.count * 3, "too few onsets for \(cell.displayName)")

            let base = onsets[0]
            XCTAssertLessThanOrEqual(base, 1, "playback must begin on sample 0 for \(cell.displayName)")

            // Map each onset to its sixteenth tick index and thus its position within the beat. Every
            // onset must (a) sit on the sixteenth grid and (b) fall on a sounding position of the cell.
            var observed = Set<Int>()
            for onset in onsets {
                let rel = Double(onset - base)
                let tick = Int((rel / framesPer16).rounded())
                XCTAssertLessThan(abs(rel - Double(tick) * framesPer16), 2.0,
                    "\(cell.displayName): onset drifted off the sixteenth grid (timing must be untouched)")
                let pos = ((tick % 4) + 4) % 4
                XCTAssertTrue(sounding.contains(pos),
                    "\(cell.displayName): a click sounded at silenced sixteenth position \(pos)")
                observed.insert(pos)
            }

            // Over several bars every sounding position appears, and NO silenced one ever does — i.e. the
            // set of positions that actually sounded equals the cell's figure exactly.
            XCTAssertEqual(observed, sounding,
                "\(cell.displayName): sounded positions \(observed.sorted()) ≠ pattern \(sounding.sorted())")

            // The cell downbeat (position 0, here the bar's strong beat) is louder than an inner sixteenth
            // (position 3 sounds in every cell) — the "accent the cell downbeat" requirement.
            func peak(atTick tick: Int) -> Float {
                let f = base + Int((Double(tick) * framesPer16).rounded())
                let end = min(f + 512, samples.count)
                var p: Float = 0
                for i in max(f, 0)..<end { p = max(p, abs(samples[i])) }
                return p
            }
            XCTAssertGreaterThan(peak(atTick: 0), peak(atTick: 3),
                "\(cell.displayName): the cell downbeat must be louder than its inner sixteenth")
        }
    }

    /// The straight cell (Off) is a genuine no-op: all four sixteenths sound, exactly as a plain sixteenth
    /// pulse — so switching a cell off restores the ordinary grid.
    func testStraightCellSoundsAllFourSixteenths() throws {
        let bpm = 90.0
        let framesPer16 = (60.0 / bpm / 4.0) * sampleRate
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common,
                                            subdivision: .sixteenth, cell: .straight)
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }

        let samples = try engine.renderOffline(config: config, seconds: 4.0)
        let onsets = Self.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        let base = onsets[0]

        var observed = Set<Int>()
        for onset in onsets {
            let tick = Int((Double(onset - base) / framesPer16).rounded())
            observed.insert(((tick % 4) + 4) % 4)
        }
        XCTAssertEqual(observed, [0, 1, 2, 3], "the straight cell must sound every sixteenth")
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
