import XCTest
@testable import Metronome

final class IndependentTimingMathTests: XCTestCase {
    // Rational rounding avoids using the production timing helpers as the expected result.
    private func nearest(_ numerator: Int64, _ denominator: Int64) -> Int {
        Int((2 * numerator + denominator) / (2 * denominator))
    }

    func testStraightGridAcrossMetersSubdivisionsRatesAndLongDurations() {
        let divisions: [(Subdivision, Int, Int)] = [
            (.quarter, 1, 1), (.eighth, 2, 3), (.triplet, 3, 3), (.sixteenth, 4, 6),
            (.quintuplet, 5, 5), (.sextuplet, 6, 6), (.septuplet, 7, 7), (.thirtysecond, 8, 12)
        ]
        for rate in [44_100, 48_000, 96_000] {
            for bpm in [30, 59, 60, 97, 137, 299, 300] {
                for top in 1...32 {
                    for bottom in [2, 4, 8, 16] {
                        let compound = bottom == 8 && top >= 6 && top % 3 == 0
                        for (division, simpleTicks, compoundTicks) in divisions {
                            let ticks = compound ? compoundTicks : simpleTicks
                            let config = MetronomeConfiguration(bpm: Double(bpm),
                                timeSignature: TimeSignature(numerator: top, denominator: bottom), subdivision: division)
                            let plan = RenderPlan(config: config, sampleRate: Double(rate))
                            XCTAssertEqual(plan.beatsPerBar, compound ? top / 3 : top)
                            XCTAssertEqual(plan.ticksPerBeat, ticks)
                            for tick in [0, 1, 7, 101, 1_000_003] {
                                let numerator = Int64(tick) * 60 * Int64(rate)
                                let denominator = Int64(bpm * ticks)
                                let actual = Int64(plan.frame(forTick: tick))
                                // At an exact half-sample either adjacent sample has the same error.
                                XCTAssertLessThanOrEqual(abs(actual * denominator - numerator) * 2, denominator)
                            }
                        }
                    }
                }
            }
        }
    }

    func testFullSwingIsTwoToOneWithoutMovingPairBoundaries() {
        for ticks in [2, 4] {
            for rate in [44_100, 48_000] {
                let plan = RenderPlan(config: MetronomeConfiguration(bpm: 137,
                    subdivision: ticks == 2 ? .eighth : .sixteenth, swing: 1), sampleRate: Double(rate))
                for tick in 0..<1000 {
                    let numerator = Int64(3 * tick + (tick % 2 == 1 ? 1 : 0)) * 60 * Int64(rate)
                    XCTAssertEqual(plan.frame(forTick: tick), nearest(numerator, Int64(137 * ticks * 3)))
                }
            }
        }
    }

    func testThousandTempoChangesCarryFractionalSamples() {
        for rate in [44_100, 48_000, 96_000] {
            let sections = (0..<1000).map { index in
                SongSection(tempoBPM: index % 2 == 0 ? 137 : 149, bars: 1)
            }
            let plan = SongPlan(song: Song(sections: sections), sampleRate: Double(rate))
            let denominator: Int64 = 137 * 149
            var elapsed: Int64 = 0
            for index in sections.indices {
                let otherBPM: Int64 = index % 2 == 0 ? 149 : 137
                for beat in 0..<4 {
                    let expected = nearest(elapsed + Int64(beat) * 60 * Int64(rate) * otherBPM, denominator)
                    XCTAssertEqual(plan.frame(at: index * 4 + beat), expected)
                }
                elapsed += 4 * 60 * Int64(rate) * otherBPM
            }
            XCTAssertEqual(plan.totalFrames, nearest(elapsed, denominator))
        }
    }

    func testSongDurationMatchesClampedAndRoundedPlaybackTempo() {
        let slow = Song(sections: [SongSection(tempoBPM: 30)], tempoScale: 0.5)
        XCTAssertEqual(slow.durationSeconds, 8, accuracy: 1e-10)
        let fast = Song(sections: [SongSection(tempoBPM: 300)], tempoScale: 2)
        XCTAssertEqual(fast.durationSeconds, 0.8, accuracy: 1e-10)
        let rounded = Song(sections: [SongSection(tempoBPM: 91)], tempoScale: 0.95)
        XCTAssertEqual(rounded.durationSeconds, 240.0 / 86.0, accuracy: 1e-10)
    }
}
