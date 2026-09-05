import XCTest
import CoreGraphics
@testable import Metronome

/// The crux tests for build 14's complaint that Smart Import "pulled in random crap but not the obvious":
/// realistic, full-page OCR observation sets (text **+ bounding boxes**) that bury the real tempo mark and
/// time signature among the distractors a real score is full of — a title, a composer, measure numbers,
/// fingerings, a dynamic, lyrics, a page number and a "© 2026" copyright. Each asserts the parser returns
/// the **right** tempo and meter and ignores the noise.
///
/// Vision's boxes use a **bottom-left** origin (y ↑ = higher on the page), so a tempo mark sits at a large
/// y toward the left, and a starting time signature is the stacked digit pair at the left of the first
/// (top) system. The pure `parse` seam takes these hand-built lines, so all of it runs in CI with no camera
/// and no image.
final class SheetMusicOCRDistractorTests: XCTestCase {

    /// A recognized line at a normalized box. `(x, y)` is the box's bottom-left origin (Vision space).
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Layout A — classical piano page: ♩ = 132 top-left, stacked 4/4, dense distractors

    func testClassicalPagePicksTempoAndMeterNotTheDistractors() {
        let page = [
            line("Sonata in C Major",   0.28, 0.95, 0.44, 0.04),   // title (non-numeric, very top)
            line("Ludwig van Beethoven",0.55, 0.90, 0.30, 0.03),   // composer
            line("Allegro",             0.08, 0.85, 0.12, 0.03),   // tempo word …
            line("♩ = 132",             0.22, 0.85, 0.12, 0.03),   // … and the real mark → 132
            line("4",                   0.11, 0.73, 0.03, 0.045),  // time signature (stacked, first system)
            line("4",                   0.11, 0.68, 0.03, 0.045),
            line("3",                   0.46, 0.76, 0.02, 0.030),  // a measure number above a barline
            line("mf",                  0.30, 0.66, 0.03, 0.025),  // a dynamic
            line("1",                   0.52, 0.71, 0.015,0.020),  // fingering …
            line("2",                   0.52, 0.68, 0.015,0.020),  // … stacked-looking (1 over 2) but NOT a meter
            line("sempre legato",       0.30, 0.60, 0.20, 0.025),  // expression text below the staff
            line("2",                   0.50, 0.04, 0.02, 0.020),  // page number (bottom)
            line("© 2026 Public Domain",0.20, 0.03, 0.40, 0.020),  // copyright year (bottom)
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertEqual(result.tempoBPM, 132, "the top-left ♩ = 132 mark, not a measure/page/fingering number")
        XCTAssertNil(result.tempoWord, "an explicit number was found, so no word is reported")
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 4, denominator: 4),
                       "the first-system stacked 4/4 — the fingering 1-over-2 must be ranked out")
    }

    // MARK: - Layout B — OCR split the mark into "♩", "=", "132" boxes; plausible measure number nearby

    func testSplitMetronomeMarkIsReassembledSpatially() {
        let page = [
            line("Moderato", 0.08, 0.86, 0.14, 0.03),   // tempo word (maps to 112 on its own)
            line("♩",        0.24, 0.86, 0.02, 0.03),   // beat glyph  ┐
            line("=",        0.27, 0.86, 0.015,0.03),   // equals      ├ three separate observations …
            line("132",      0.30, 0.86, 0.05, 0.03),   // number      ┘ … that together mean ♩ = 132
            line("3",        0.10, 0.72, 0.03, 0.045),  // stacked 3/4 at the first system
            line("4",        0.10, 0.68, 0.03, 0.045),
            line("112",      0.40, 0.74, 0.03, 0.020),  // a measure number *inside* the plausible BPM band
            line("© 2026",   0.45, 0.03, 0.10, 0.020),
            line("Page 3",   0.90, 0.03, 0.06, 0.020),
        ]
        let result = SheetMusicOCRParser.parse(page)
        // 132 wins because a glyph/= cue box sits right beside it; the measure number 112 is plausible in
        // value but has no tempo context, and the word would have said 112 — the number is preferred.
        XCTAssertEqual(result.tempoBPM, 132)
        XCTAssertNil(result.tempoWord)
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 3, denominator: 4))
    }

    // MARK: - Layout C — cut time + a word tempo; a bottom "44" must NOT be read as 4/4

    func testCutTimeAndWordTempoWithBottomNumberIgnored() {
        let page = [
            line("Vivace", 0.09, 0.85, 0.10, 0.03),   // word tempo → 166 (no number on the page)
            line("¢",      0.12, 0.72, 0.02, 0.045),  // cut time at the first system → 2/2
            line("44",     0.90, 0.03, 0.04, 0.020),  // bottom-right "44" (a page/opus number) — not a meter
            line("© 2026", 0.40, 0.03, 0.10, 0.020),
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertEqual(result.tempoBPM, 166)
        XCTAssertEqual(result.tempoWord, "Vivace")
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 2, denominator: 2),
                       "cut time — the bottom-margin 44 is positionally ruled out as a fused 4/4")
    }

    // MARK: - Layout D — stacked 3/4 beats a stray "C" chord symbol and a measure number

    func testStackedMeterBeatsStrayChordSymbolAndMeasureNumber() {
        let page = [
            line("Allegretto", 0.09, 0.86, 0.15, 0.03),   // word (116) …
            line("♩ = 116",    0.26, 0.86, 0.12, 0.03),   // … and the real mark → 116
            line("3",          0.11, 0.72, 0.03, 0.045),  // stacked 3/4 at the first system
            line("4",          0.11, 0.68, 0.03, 0.045),
            line("C",          0.60, 0.78, 0.02, 0.03),   // a C chord symbol above the staff — not common time
            line("24",         0.44, 0.74, 0.03, 0.02),   // a measure number (24) off to the right
            line("mp",         0.30, 0.64, 0.03, 0.025),  // dynamic
            line("Page 12",    0.90, 0.03, 0.06, 0.02),
            line("© 2026",     0.35, 0.03, 0.10, 0.02),
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertEqual(result.tempoBPM, 116)
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 3, denominator: 4),
                       "the left, first-system 3/4 — a right-side chord 'C' and measure 24 are ruled out")
    }

    // MARK: - Layout E — two real marks: the top one wins, the other is kept as the runner-up

    func testTopmostMarkChosenAndSecondKeptAsAlternative() {
        let page = [
            line("♩ = 120", 0.10, 0.86, 0.12, 0.03),   // starting tempo, top → chosen
            line("poco meno mosso", 0.35, 0.45, 0.24, 0.03),
            line("♩ = 96",  0.10, 0.40, 0.12, 0.03),   // a later tempo change, lower → runner-up
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertEqual(result.tempoBPM, 120, "the higher (first-system) mark is the starting tempo")
        XCTAssertEqual(result.tempoAlternativeBPM, 96, "the second mark is retained as a one-tap alternative")
    }

    // MARK: - Layout F — a page of pure distractors fabricates nothing

    func testPureDistractorsDetectNothing() {
        let page = [
            line("Étude",   0.30, 0.95, 0.16, 0.04),   // title
            line("3",       0.45, 0.78, 0.02, 0.02),   // fingering / measure digit
            line("5",       0.62, 0.74, 0.02, 0.02),   // fingering
            line("mf",      0.30, 0.64, 0.03, 0.025),  // dynamic
            line("la la la",0.30, 0.55, 0.18, 0.025),  // lyrics below the staff
            line("© 2026",  0.40, 0.03, 0.10, 0.02),   // copyright
            line("Page 7",  0.90, 0.03, 0.06, 0.02),   // page number
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertNil(result.tempoBPM, "no number is part of a tempo expression, so none is chosen")
        XCTAssertNil(result.timeSignature, "scattered single digits are not a meter")
        XCTAssertFalse(result.hasAnyDetection)
    }
}
