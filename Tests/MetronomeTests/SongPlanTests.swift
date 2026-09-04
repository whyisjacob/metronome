import XCTest
@testable import Metronome

/// Pure, deterministic proof that `SongPlan` expands a multi-section tempo-map onto the correct
/// sample grid — and, critically, with **zero cumulative drift across section boundaries**.
///
/// Like `OfflineRenderAccuracyTests`, the oracle here is built **independently from first principles**
/// and never consults `SongPlan`'s output:
///
///   * `secondsPerBeat = 60 / BPM`, split into `ticksPerBeat` equal clicks, where `ticksPerBeat` is
///     the subdivision's *musical* meaning written out per case (quarter 1, eighth 2, triplet 3,
///     sixteenth 4) — NOT read from `Subdivision.ticksPerBeat`.
///   * A running **integer** frame cursor: section `s` begins at the sum of the earlier sections'
///     rounded integer lengths; click `i` within it is `cursor + round(i × secondsPerTick × sr)`; the
///     cursor then advances by `round(totalTicks × secondsPerTick × sr)` (rounded once).
///
/// This is the definition the task specifies. If `SongPlan` accumulated per-tick durations, forgot to
/// round a boundary once, or switched tempo/meter/subdivision on the wrong tick, its frames would
/// diverge from this oracle and the tests fail. The math is never bent to match `SongPlan`.
final class SongPlanTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Independent oracle

    /// A section described by its raw musical numbers, with `ticksPerBeat` stated explicitly so the
    /// expected grid does not depend on the production `Subdivision.ticksPerBeat` mapping under test.
    fileprivate struct Spec {
        let name: String
        let bpm: Double
        let numerator: Int
        let denominator: Int
        let subdivision: Subdivision
        let ticksPerBeat: Int
        let bars: Int
        let repeatCount: Int
        let accents: [Bool]
    }

    fileprivate struct ExpectedClick {
        let frame: Int
        let section: Int
        let localTick: Int
        let bar: Int
        let beatInBar: Int?
        let accent: AccentLevel
    }

    fileprivate struct Oracle {
        let clicks: [ExpectedClick]
        let sectionStarts: [Int]        // count == specs.count + 1 (last entry == totalFrames)
        let sectionClickCounts: [Int]
        let framesPerTick: [Double]     // per-section continuous frames/tick
        let firstClickIndex: [Int]      // index of each section's first click in the flat stream
        var totalFrames: Int { sectionStarts.last ?? 0 }
    }

    /// Builds the expected click stream from first principles. No `SongPlan`, `SongSection`, or engine
    /// timing is consulted — only the raw `Spec` numbers and hard-coded `ticksPerBeat`.
    fileprivate func buildOracle(_ specs: [Spec], sampleRate: Double) -> Oracle {
        var clicks: [ExpectedClick] = []
        var starts: [Int] = []
        var counts: [Int] = []
        var fpts: [Double] = []
        var firsts: [Int] = []
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
                let bar = i / ticksPerBar
                let beatInBar: Int? = (tickWithinBar % spec.ticksPerBeat == 0)
                    ? tickWithinBar / spec.ticksPerBeat
                    : nil
                let accent: AccentLevel
                if let b = beatInBar {
                    accent = (spec.accents.indices.contains(b) && spec.accents[b]) ? .strong : .normal
                } else {
                    accent = .weak
                }
                clicks.append(ExpectedClick(frame: frame, section: s, localTick: i,
                                            bar: bar, beatInBar: beatInBar, accent: accent))
            }
            // Advance the integer cursor by the section's total length, rounded to samples ONCE.
            cursor += Int((Double(totalTicks) * fpt).rounded())
        }
        starts.append(cursor)
        return Oracle(clicks: clicks, sectionStarts: starts, sectionClickCounts: counts,
                      framesPerTick: fpts, firstClickIndex: firsts)
    }

    fileprivate func makeSong(_ specs: [Spec]) -> Song {
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

    /// A representative multi-section tempo-map used by several tests: tempo, meter, subdivision, and
    /// accents all change at least once, including an odd (7/8) meter and every subdivision family.
    private var richSpecs: [Spec] {
        [
            Spec(name: "Intro",  bpm: 120, numerator: 4, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 1, accents: [true, false, false, false]),
            Spec(name: "Verse",  bpm: 90,  numerator: 3, denominator: 4, subdivision: .eighth,
                 ticksPerBeat: 2, bars: 2, repeatCount: 2, accents: [true, false, true]),
            Spec(name: "Bridge", bpm: 144, numerator: 7, denominator: 8, subdivision: .triplet,
                 ticksPerBeat: 3, bars: 1, repeatCount: 1, accents: [true, false, false, true, false, false, false]),
            Spec(name: "Outro",  bpm: 200, numerator: 4, denominator: 4, subdivision: .sixteenth,
                 ticksPerBeat: 4, bars: 1, repeatCount: 1, accents: [true, false, false, false]),
        ]
    }

    // MARK: - Structure: counts and boundaries

    func testClickCountAndSectionBoundariesMatchOracle() {
        let specs = richSpecs
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        XCTAssertEqual(plan.clickCount, oracle.clicks.count,
            "total click count must equal the independently expanded grid")
        XCTAssertEqual(plan.totalFrames, oracle.totalFrames,
            "total song length must equal the sum of independently rounded section lengths")
        XCTAssertEqual(plan.sectionClickCounts, oracle.sectionClickCounts)
        XCTAssertEqual(plan.sectionStartFrames, oracle.sectionStarts,
            "each section must start on the independently computed integer cursor")
    }

    // MARK: - Every click on the independent grid

    func testEveryClickMatchesIndependentGrid() {
        let specs = richSpecs
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        XCTAssertEqual(plan.clickCount, oracle.clicks.count)
        for k in 0..<min(plan.clickCount, oracle.clicks.count) {
            let e = oracle.clicks[k]
            XCTAssertEqual(plan.frame(at: k), e.frame, "click \(k) frame")
            XCTAssertEqual(plan.accent(at: k), e.accent, "click \(k) accent")
            XCTAssertEqual(plan.sectionIndex(at: k), e.section, "click \(k) section")
            XCTAssertEqual(plan.barInSection(at: k), e.bar, "click \(k) bar")
            XCTAssertEqual(plan.beatInBar(at: k), e.beatInBar, "click \(k) beat-in-bar")
        }
    }

    // MARK: - Zero drift (closed form, no accumulation)

    /// Within each section the placed frame stays within ½ sample of the *continuous* ideal anchored
    /// at that section's integer start — for EVERY click, the last as tight as the first. A scheme that
    /// summed per-tick durations would drift past ½ sample within the first bar and fail here.
    func testZeroDriftWithinSectionsAgainstContinuousIdeal() {
        let specs = richSpecs
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        for k in 0..<plan.clickCount {
            let e = oracle.clicks[k]
            let idealContinuous = Double(oracle.sectionStarts[e.section])
                + Double(e.localTick) * oracle.framesPerTick[e.section]
            XCTAssertLessThanOrEqual(abs(Double(plan.frame(at: k)) - idealContinuous), 0.5,
                "click \(k) (section \(e.section), localTick \(e.localTick)) drifted off the closed form")
        }
    }

    // MARK: - Boundary exactness (a ≥1 sample error fails)

    /// Each section's first click lands exactly on the independently computed integer cursor. Frames
    /// are `Int`, so this is exact equality: a boundary misplaced by even one sample fails outright.
    func testSectionBoundariesLandExactlyOnIntegerCursor() {
        let specs = richSpecs
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        for s in specs.indices {
            let k = oracle.firstClickIndex[s]
            XCTAssertEqual(plan.frame(at: k), oracle.sectionStarts[s],
                "section \(s) boundary must be exact (a ≥1 sample error fails)")
            XCTAssertEqual(plan.sectionIndex(at: k), s)
            XCTAssertEqual(plan.barInSection(at: k), 0, "a section starts on its own bar 0")
            XCTAssertEqual(plan.beatInBar(at: k), 0, "a section starts on its downbeat")
        }
    }

    // MARK: - Tempo / meter / subdivision switch on the correct tick

    /// The inter-click spacing is the new section's tempo/subdivision starting exactly at its first
    /// click, and the click density per bar reflects the new subdivision — the switch is not one tick
    /// early or late.
    func testTempoAndSubdivisionSwitchAtSectionStart() {
        let specs = richSpecs
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        for s in specs.indices {
            let first = oracle.firstClickIndex[s]
            let fpt = oracle.framesPerTick[s]

            // The spacing to the section's SECOND click equals the new section's frames/tick (rounded),
            // proving the new tempo/subdivision is in force from the very first click.
            if oracle.sectionClickCounts[s] >= 2 {
                let spacing = plan.frame(at: first + 1) - plan.frame(at: first)
                XCTAssertEqual(Double(spacing), fpt, accuracy: 0.5,
                    "section \(s) must use its own tempo/subdivision from its first click")
            }

            // Click density per bar == ticksPerBeat × numerator for THIS section's subdivision/meter.
            let expectedPerBar = specs[s].ticksPerBeat * specs[s].numerator
            XCTAssertEqual(plan.sectionClickCounts[s],
                           expectedPerBar * specs[s].bars * specs[s].repeatCount,
                           "section \(s) click density must reflect its own meter × subdivision")
        }
    }

    // MARK: - Repeats

    func testRepeatsExpandBarsAndRepeatAccentPattern() {
        let specs = [
            Spec(name: "Loop", bpm: 100, numerator: 4, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 3, accents: [true, false, true, false])
        ]
        let oracle = buildOracle(specs, sampleRate: sampleRate)
        let plan = SongPlan(song: makeSong(specs), sampleRate: sampleRate)

        // 2 bars × 3 repeats × 4 beats = 24 clicks; bar index runs 0…5.
        XCTAssertEqual(plan.clickCount, 24)
        XCTAssertEqual(plan.barInSection(at: 23), 5)
        for k in 0..<plan.clickCount {
            // Accent pattern [strong, normal, strong, normal] repeats every bar across all repeats.
            XCTAssertEqual(plan.accent(at: k), oracle.clicks[k].accent, "click \(k)")
        }
        XCTAssertEqual(plan.accent(at: 0), .strong)   // bar 0 beat 0
        XCTAssertEqual(plan.accent(at: 2), .strong)   // bar 0 beat 2 (custom accent)
        XCTAssertEqual(plan.accent(at: 8), .strong)   // bar 2 beat 0 — pattern repeats
    }

    // MARK: - Hand-computed, clean sample rate (human-verifiable, fully independent)

    /// At 48 kHz these tempos give exact-integer frames/tick, so the whole grid — including the two
    /// section boundaries at 192000 and 408000 — can be written down by hand and asserted with `==`.
    func testHandComputedGridAtCleanSampleRate() {
        let sr = 48_000.0
        let specs = [
            // fpt = (60/120)/1 × 48000 = 24000; 2 bars × 4 = 8 clicks; length = 192000.
            Spec(name: "A", bpm: 120, numerator: 4, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 1, accents: [true, false, false, false]),
            // fpt = (60/80)/1 × 48000 = 36000; 2 bars × 3 = 6 clicks; length = 216000; cursor → 408000.
            Spec(name: "B", bpm: 80, numerator: 3, denominator: 4, subdivision: .quarter,
                 ticksPerBeat: 1, bars: 2, repeatCount: 1, accents: [true, false, false]),
            // fpt = (60/60)/2 × 48000 = 24000; 1 bar × 8 = 8 clicks; length = 192000; cursor → 600000.
            Spec(name: "C", bpm: 60, numerator: 4, denominator: 4, subdivision: .eighth,
                 ticksPerBeat: 2, bars: 1, repeatCount: 1, accents: [true, false, false, false]),
        ]
        let plan = SongPlan(song: makeSong(specs), sampleRate: sr)

        XCTAssertEqual(plan.clickCount, 22)
        XCTAssertEqual(plan.sectionStartFrames, [0, 192_000, 408_000, 600_000])
        XCTAssertEqual(plan.totalFrames, 600_000)

        // Section A clicks: 0, 24000, …, 168000.
        XCTAssertEqual(plan.frame(at: 0), 0)
        XCTAssertEqual(plan.frame(at: 7), 168_000)
        // Section B boundary + last click.
        XCTAssertEqual(plan.frame(at: 8), 192_000)
        XCTAssertEqual(plan.frame(at: 13), 372_000)      // 192000 + 5×36000
        // Section C boundary + last click.
        XCTAssertEqual(plan.frame(at: 14), 408_000)
        XCTAssertEqual(plan.frame(at: 21), 576_000)      // 408000 + 7×24000

        // Accents survive the meter/subdivision switches.
        XCTAssertEqual(plan.accent(at: 0), .strong)      // A downbeat
        XCTAssertEqual(plan.accent(at: 4), .strong)      // A bar 1 downbeat
        XCTAssertEqual(plan.accent(at: 8), .strong)      // B downbeat
        XCTAssertEqual(plan.accent(at: 9), .normal)      // B beat 2
        XCTAssertEqual(plan.accent(at: 14), .strong)     // C downbeat
        XCTAssertEqual(plan.accent(at: 15), .weak)       // C first eighth-note subdivision
        XCTAssertEqual(plan.accent(at: 16), .normal)     // C beat 2
        XCTAssertEqual(plan.beatInBar(at: 14), 0)
        XCTAssertNil(plan.beatInBar(at: 15))             // subdivision click, not a beat
        XCTAssertEqual(plan.beatInBar(at: 16), 1)
    }

    // MARK: - Degenerate inputs

    func testEmptySongProducesEmptyPlan() {
        let plan = SongPlan(song: Song(name: "Empty", sections: []), sampleRate: sampleRate)
        XCTAssertEqual(plan.clickCount, 0)
        XCTAssertEqual(plan.totalFrames, 0)
        XCTAssertTrue(plan.isEmpty)
    }
}
