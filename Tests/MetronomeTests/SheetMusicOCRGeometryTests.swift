import XCTest
import CoreGraphics
@testable import Metronome

/// Tests for the geometry- and misread-tolerant OCR parsing a real score actually needs: a **stacked**
/// time signature (numerator box directly above the denominator box, no slash), a stack OCR fused into one
/// token ("44" → 4/4), and tempo marks whose quarter-note glyph OCR mangled into "J"/"q"/"quarter" or
/// dropped. The pure `parse` seams take hand-built lines + boxes, so all of this is verifiable in CI with
/// no camera and no image.
final class SheetMusicOCRGeometryTests: XCTestCase {

    /// A digit's recognized line with a bounding box. Vision's boxes use a **bottom-left** origin, so a
    /// larger `y` is higher on the page — a numerator sits above its denominator.
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.04, h: CGFloat = 0.05) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Stacked time signature (the real, no-slash shape)

    func testStackedNumeratorOverDenominator() {
        // "3" directly above "4" at the same x → 3/4.
        let ts = SheetMusicOCRParser.parse([line("3", x: 0.10, y: 0.60), line("4", x: 0.10, y: 0.52)]).timeSignature
        XCTAssertEqual(ts, TimeSignature(numerator: 3, denominator: 4))
    }

    func testStackedSixOverEightIsCompound() {
        let result = SheetMusicOCRParser.parse([line("6", x: 0.12, y: 0.62), line("8", x: 0.12, y: 0.54)])
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 6, denominator: 8))
        XCTAssertEqual(result.timeSignature?.isCompound, true)
    }

    func testStackedSevenOverEightAndTwelveOverEight() {
        XCTAssertEqual(SheetMusicOCRParser.parse([line("7", x: 0.1, y: 0.60), line("8", x: 0.1, y: 0.52)]).timeSignature,
                       TimeSignature(numerator: 7, denominator: 8))
        // A two-digit numerator box ("12") over "8" → 12/8.
        XCTAssertEqual(SheetMusicOCRParser.parse([line("12", x: 0.10, y: 0.60, w: 0.07), line("8", x: 0.11, y: 0.52)]).timeSignature,
                       TimeSignature(numerator: 12, denominator: 8))
    }

    func testSideBySideDigitsAreNotAStackedMeter() {
        // Two "4"s at the SAME height, side by side (not stacked) → no meter fabricated.
        let ts = SheetMusicOCRParser.parse([line("4", x: 0.10, y: 0.55), line("4", x: 0.30, y: 0.55)]).timeSignature
        XCTAssertNil(ts)
    }

    func testStackedWithNonMusicalDenominatorRejected() {
        // "3" over "5": 5 is not a musical denominator and 3 isn't allowed as one either → nil.
        let ts = SheetMusicOCRParser.parse([line("3", x: 0.1, y: 0.60), line("5", x: 0.1, y: 0.52)]).timeSignature
        XCTAssertNil(ts)
    }

    func testStackedGeometryPreferredOverAFusedDigitElsewhere() {
        // Boxes say 3/4; a stray "44" (e.g. a measure number) elsewhere must not override the real stack.
        let lines = [line("3", x: 0.10, y: 0.60), line("4", x: 0.10, y: 0.52),
                     RecognizedTextLine(text: "44", boundingBox: CGRect(x: 0.80, y: 0.90, width: 0.06, height: 0.04))]
        XCTAssertEqual(SheetMusicOCRParser.parse(lines).timeSignature, TimeSignature(numerator: 3, denominator: 4))
    }

    // MARK: - Fused single-token meter (a stack OCR'd as one string)

    func testFusedDigitMeters() {
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["44"]).timeSignature, TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["68"]).timeSignature, TimeSignature(numerator: 6, denominator: 8))
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["34"]).timeSignature, TimeSignature(numerator: 3, denominator: 4))
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["916"]).timeSignature, TimeSignature(numerator: 9, denominator: 16))
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["128"]).timeSignature, TimeSignature(numerator: 12, denominator: 8))
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["4 4"]).timeSignature, TimeSignature(numerator: 4, denominator: 4))
    }

    func testFusedDigitDoesNotEatTempoLikeNumbers() {
        // A lone "120" is not a meter (ends in 0), and with no glyph/=/word it isn't a tempo either.
        let result = SheetMusicOCRParser.parse(recognizedLines: ["120"])
        XCTAssertNil(result.timeSignature)
        XCTAssertNil(result.tempoBPM)
        // A 4-digit year won't split into a valid meter.
        XCTAssertNil(SheetMusicOCRParser.parse(recognizedLines: ["2024"]).timeSignature)
    }

    // MARK: - Tempo with a mangled / absent note glyph

    func testTempoWithMisreadOrAbsentQuarterGlyph() {
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["J = 120"]).tempoBPM, 120)
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["q = 132"]).tempoBPM, 132)
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["quarter note = 96"]).tempoBPM, 96)
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["quarter = 88"]).tempoBPM, 88)
        XCTAssertEqual(SheetMusicOCRParser.parse(recognizedLines: ["J=100"]).tempoBPM, 100)
    }

    func testMisreadGlyphLetterDoesNotFalseMatchInsideWords() {
        // A "J"/"q" embedded in an ordinary word must not be read as a metronome mark.
        XCTAssertNil(SheetMusicOCRParser.parse(recognizedLines: ["Justin 24"]).tempoBPM)
        XCTAssertNil(SheetMusicOCRParser.parse(recognizedLines: ["Baroque 30"]).tempoBPM)
    }
}
