import XCTest
import AVFoundation
@testable import Metronome

/// Music-theory correctness for the **labels and default accents** that a working musician caught being
/// wrong outside ×/4 meters — plus a proof that fixing them moved **no click**.
///
/// Three independent things are asserted here:
///   1. `Subdivision.displayName(in:)` names each click by its TRUE note value for the meter's actual beat
///      unit (denominator note, or dotted quarter when compound) — not the old ×/4-only names.
///   2. `TimeSignature.defaultAccents` gives the musically-correct hierarchy for the fixed meters
///      (4/2, 12/8, 6/4) and is UNCHANGED for the ones that were already right (4/4, 6/8, 9/8, 3/4, 7/8).
///   3. Those are label/accent changes only: rendered click ONSETS still land on the first-principles grid
///      (hand-derived, never read from `RenderPlan`/`SongPlan`) and are identical to a flat accent pattern.
final class TheoryLabelsAndAccentsTests: XCTestCase {

    // MARK: - 1. Subdivision names tell the musical truth in every meter

    /// The user reported: "i don't think all the count options are accurate such as 4/2." They're right —
    /// `Subdivision` is clicks-per-beat, and the beat is the DENOMINATOR note. So "1 per beat" in 4/2 is a
    /// HALF note (was mislabelled "Quarter"), in 3/8 an EIGHTH (was "Quarter"), etc. Each expected string
    /// below is the true note value / beat-relative name, derived by hand from the beat unit.
    func testSubdivisionDisplayNamesReflectTheActualBeatUnit() {
        func ts(_ n: Int, _ d: Int) -> TimeSignature { TimeSignature(numerator: n, denominator: d) }

        // (numerator, denominator) → [subdivision : expected label]
        let expectations: [(TimeSignature, [(Subdivision, String)])] = [
            // ×/4 — the beat IS a quarter, so the classic names are correct (triplet now names its member).
            (ts(4, 4), [
                (.quarter, "Quarter"), (.eighth, "Eighth"), (.triplet, "Eighth triplet"),
                (.sixteenth, "Sixteenth"), (.quintuplet, "Quintuplet"), (.sextuplet, "Sextuplet"),
                (.septuplet, "Septuplet"), (.thirtysecond, "32nd"),
            ]),
            // ×/2 — beat is a HALF note. This is the meter the user was in.
            (ts(2, 2), [
                (.quarter, "Half"), (.eighth, "Quarter"), (.triplet, "Quarter triplet"),
                (.sixteenth, "Eighth"), (.thirtysecond, "Sixteenth"),
            ]),
            (ts(4, 2), [
                (.quarter, "Half"), (.eighth, "Quarter"), (.triplet, "Quarter triplet"),
                (.sixteenth, "Eighth"), (.thirtysecond, "Sixteenth"),
            ]),
            // ×/8 (simple: 3/8, 7/8) — beat is an EIGHTH note. 32nds run past the named range → beat-relative.
            (ts(3, 8), [
                (.quarter, "Eighth"), (.eighth, "Sixteenth"), (.triplet, "Sixteenth triplet"),
                (.sixteenth, "32nd"), (.thirtysecond, "⅛ beat"),
            ]),
            (ts(7, 8), [
                (.quarter, "Eighth"), (.eighth, "Sixteenth"), (.triplet, "Sixteenth triplet"),
                (.sixteenth, "32nd"), (.thirtysecond, "⅛ beat"),
            ]),
            // Compound — beat is a dotted quarter; the compound-aware names are kept (Main beat / Eighths /
            // Sixteenths are the only options offered there).
            (ts(6, 8), [
                (.quarter, "Main beat"), (.eighth, "Eighths"), (.sixteenth, "Sixteenths"),
            ]),
            (ts(12, 8), [
                (.quarter, "Main beat"), (.eighth, "Eighths"), (.sixteenth, "Sixteenths"),
            ]),
        ]

        for (signature, pairs) in expectations {
            for (sub, expected) in pairs {
                XCTAssertEqual(sub.displayName(in: signature), expected,
                    "\(sub) in \(signature.displayString) should read \"\(expected)\"")
            }
        }

        // Explicit regression on the reported bug: 4/2 "one per beat" must NOT still say "Quarter".
        XCTAssertEqual(Subdivision.quarter.displayName(in: ts(4, 2)), "Half")
        XCTAssertNotEqual(Subdivision.quarter.displayName(in: ts(4, 2)), "Quarter")
        XCTAssertTrue(ts(6, 8).isCompound)
        XCTAssertTrue(ts(12, 8).isCompound)
        XCTAssertFalse(ts(3, 8).isCompound)   // 3/8 is simple, not compound
        XCTAssertFalse(ts(7, 8).isCompound)
    }

    // MARK: - 2. Default accents follow the correct metric hierarchy

    /// The fixed / verified defaults, and — just as important — the ones that must stay UNCHANGED. These are
    /// defaults only; the accent row still lets the user override any beat.
    func testDefaultAccents() {
        func accents(_ n: Int, _ d: Int) -> [BeatAccent] {
            TimeSignature(numerator: n, denominator: d).defaultAccents
        }

        // --- Fixed / verified this build ---
        // 4/2 — compound-4 hierarchy, secondary on beat 3 (same shape as 4/4).
        XCTAssertEqual(accents(4, 2), [.strong, .normal, .medium, .normal])
        XCTAssertEqual(accents(3, 2), [.strong, .normal, .normal])
        XCTAssertEqual(accents(2, 2), [.strong, .normal])
        // 12/8 — compound 4/4: secondary on the THIRD dotted-quarter beat, NOT a flat run of mediums.
        XCTAssertEqual(accents(12, 8), [.strong, .normal, .medium, .normal])
        // 6/4 — felt in two: secondary on beat 4.
        XCTAssertEqual(accents(6, 4), [.strong, .normal, .normal, .medium, .normal, .normal])

        // --- Must be UNCHANGED (regression guards) ---
        XCTAssertEqual(accents(4, 4), [.strong, .normal, .medium, .normal])
        XCTAssertEqual(accents(6, 8), [.strong, .medium])
        XCTAssertEqual(accents(9, 8), [.strong, .medium, .medium])
        XCTAssertEqual(accents(3, 4), [.strong, .normal, .normal])
        XCTAssertEqual(accents(7, 8), [.strong, .normal, .medium, .normal, .medium, .normal, .normal])
    }

    // MARK: - 3. Timing invariance — the label/accent fixes moved no click

    private let sampleRate = 44_100.0

    /// 6/4 and 12/8 are the meters whose DEFAULT accents changed. Accents pick a click's LOUDNESS, never its
    /// onset frame, so the rendered onsets must (a) be identical whether we use the new default accents or a
    /// flat all-`.normal` pattern, and (b) sit exactly on the first-principles grid — a main beat lasts
    /// `60/BPM` seconds (a dotted quarter in 12/8 — the compound convention; a quarter in 6/4), so beat `k`
    /// is due at `round(k · 60/BPM · sampleRate)`. The grid is hand-derived here; nothing is read back from
    /// `RenderPlan`/`SongPlan`. This mirrors the discipline of `OfflineRenderAccuracyTests`.
    func testAccentDefaultChangesDoNotMoveClickPositions() throws {
        struct Case { let bpm: Double; let ts: TimeSignature; let mainBeats: Int }
        let cases = [
            Case(bpm: 120, ts: TimeSignature(numerator: 6, denominator: 4), mainBeats: 6),
            Case(bpm: 138, ts: TimeSignature(numerator: 12, denominator: 8), mainBeats: 4),
        ]

        for c in cases {
            let framesPerBeat = (60.0 / c.bpm) * sampleRate      // first principles; never from the engine
            let bars = 3
            let seconds = Double(bars * c.mainBeats) * (60.0 / c.bpm) + 0.25

            func render(_ accents: [BeatAccent]) throws -> [Int] {
                let config = MetronomeConfiguration(bpm: c.bpm, timeSignature: c.ts,
                                                    subdivision: .quarter, accents: accents)
                let engine = MetronomeEngine()
                try engine.prepareForOfflineRendering(sampleRate: sampleRate)
                defer { engine.teardownOfflineRendering() }
                let samples = try engine.renderOffline(config: config, seconds: seconds)
                return OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
            }

            let defaultOnsets = try render(c.ts.defaultAccents)                              // the new defaults
            let flatOnsets = try render([BeatAccent](repeating: .normal, count: c.mainBeats)) // flat baseline

            XCTAssertGreaterThan(defaultOnsets.count, 2, "too few onsets for \(c.ts.displayString)")

            // (A) The accent choice adds, drops, and moves NOTHING.
            XCTAssertEqual(defaultOnsets.count, flatOnsets.count,
                "accent pattern changed the onset count for \(c.ts.displayString)")
            for k in 0..<min(defaultOnsets.count, flatOnsets.count) {
                XCTAssertLessThanOrEqual(abs(defaultOnsets[k] - flatOnsets[k]), 1,
                    "accent pattern moved onset \(k) for \(c.ts.displayString)")
            }

            // (B) Every onset sits on the independent first-principles grid, drift-free.
            let base = defaultOnsets[0]
            XCTAssertLessThanOrEqual(base, 1, "playback must begin on sample 0 for \(c.ts.displayString)")
            let comparable = min(defaultOnsets.count, bars * c.mainBeats)
            XCTAssertGreaterThan(comparable, 2)
            for k in 0..<comparable {
                let idealContinuous = Double(k) * framesPerBeat
                let measured = Double(defaultOnsets[k] - base)
                XCTAssertLessThan(abs(measured - idealContinuous), 1.0,
                    "onset \(k) drifted for \(c.ts.displayString): measured \(measured), ideal \(idealContinuous)")
            }
        }
    }
}
