import XCTest
import CoreGraphics
@testable import Metronome

/// The classical/vocal-score tests: the real failing input was four photos of Handel's "Come Unto Me"
/// (R.D. Row, 1963), whose tempo is the *Italian phrase* "Largo assai e piano" (no metronome number
/// anywhere) over a stacked **12/8**, buried under penciled counting ("1 2 3 4 5 6 7"), a catalog code
/// ("R 8039"), a copyright year ("1963" / "MCMLXIII") and a page number. The correct read is **12/8, ~46
/// BPM** (Largo assai + compound meter). These exercise the pure `SheetMusicOCRParser` seam with hand-built
/// observation sets, so the whole extraction runs in CI with no camera and no image.
final class SheetMusicOCRScoreTests: XCTestCase {

    /// A recognized line at a normalized box. `(x, y)` is the box's bottom-left origin (Vision space,
    /// y ↑ = higher on the page).
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RecognizedTextLine {
        RecognizedTextLine(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    private func parse(_ lines: [String]) -> SheetMusicImportResult {
        SheetMusicOCRParser.parse(recognizedLines: lines)
    }

    // MARK: - The crux: Handel "Come Unto Me" full page

    func testHandelComeUntoMeReadsLargoAssaiAndTwelveEight() {
        let page = [
            // Tempo is an Italian phrase with NO metronome number: "Largo assai" → slow end (~46).
            line("Largo assai e piano", 0.08, 0.90, 0.34, 0.03),
            // Title / composer / catalog code (top).
            line("Come Unto Me",        0.30, 0.955, 0.40, 0.035),
            line("G. F. Handel",        0.60, 0.92, 0.22, 0.03),
            line("R 8039",              0.88, 0.955, 0.08, 0.02),   // catalog code — not a tempo/meter
            // Penciled beat counting strung left-to-right across a band over the vocal staff.
            line("1", 0.30, 0.72, 0.015, 0.02),
            line("2", 0.36, 0.72, 0.015, 0.02),
            line("3", 0.42, 0.72, 0.015, 0.02),
            line("4", 0.48, 0.72, 0.015, 0.02),
            line("5", 0.54, 0.72, 0.015, 0.02),
            line("6", 0.60, 0.72, 0.015, 0.02),
            line("7", 0.66, 0.72, 0.015, 0.02),
            // The real, stacked 12/8 at the left of the first (piano) system.
            line("12", 0.09, 0.66, 0.05, 0.045),   // numerator
            line("8",  0.10, 0.61, 0.03, 0.045),   // denominator
            // A recitative common-time "C" on a later system — must NOT beat the first-system 12/8.
            line("C", 0.09, 0.40, 0.03, 0.03),
            // Lyrics + a dynamic (noise).
            line("Come un - to me", 0.30, 0.55, 0.30, 0.025),
            line("p", 0.30, 0.50, 0.01, 0.02),
            // Copyright + page number (bottom margin).
            line("Copyright 1963 by R.D. Row", 0.20, 0.04, 0.42, 0.02),
            line("MCMLXIII", 0.72, 0.05, 0.10, 0.02),   // Roman-numeral year (no digits → inert)
            line("45", 0.93, 0.03, 0.03, 0.02),         // page number
        ]
        let result = SheetMusicOCRParser.parse(page)

        // Tempo: the phrase "Largo assai" wins (no numeric mark survives), landing at the slow end ~46.
        XCTAssertEqual(result.tempoBPM, 46, "Largo assai → slow end ~46, ignoring 'e piano' (a dynamic)")
        XCTAssertEqual(result.tempoWord, "Largo assai")
        XCTAssertNil(result.tempoAlternativeBPM, "no numeric candidate survived, so there is no runner-up")

        // Meter: the first-system stacked 12/8 — compound, felt in 4 dotted-quarter beats.
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 12, denominator: 8))
        XCTAssertEqual(result.timeSignature?.isCompound, true)
        XCTAssertEqual(result.timeSignature?.beatsPerBar, 4)

        // None of the distractors were chosen: not a counting integer (1…7), catalog (8039), year (1963),
        // or page number (45), and not the recitative "C".
        XCTAssertNotEqual(result.tempoBPM, 8039)
        XCTAssertNotEqual(result.timeSignature, TimeSignature(numerator: 4, denominator: 4))
    }

    // MARK: - Expanded tempo table (base absolute terms)

    func testExpandedTempoTableRepresentativeValues() {
        XCTAssertEqual(parse(["Grave"]).tempoBPM, 35)
        XCTAssertEqual(parse(["Largo"]).tempoBPM, 48)
        XCTAssertEqual(parse(["Lento"]).tempoBPM, 52)
        XCTAssertEqual(parse(["Larghetto"]).tempoBPM, 60)
        XCTAssertEqual(parse(["Adagio"]).tempoBPM, 68)
        XCTAssertEqual(parse(["Adagietto"]).tempoBPM, 75)
        XCTAssertEqual(parse(["Andante"]).tempoBPM, 92)
        XCTAssertEqual(parse(["Andantino"]).tempoBPM, 96)
        XCTAssertEqual(parse(["Moderato"]).tempoBPM, 112)
        XCTAssertEqual(parse(["Allegretto"]).tempoBPM, 116)
        XCTAssertEqual(parse(["Allegro"]).tempoBPM, 138)
        XCTAssertEqual(parse(["Vivo"]).tempoBPM, 160)
        XCTAssertEqual(parse(["Vivace"]).tempoBPM, 166)
        XCTAssertEqual(parse(["Presto"]).tempoBPM, 184)
        XCTAssertEqual(parse(["Prestissimo"]).tempoBPM, 204)
    }

    // MARK: - Phrase modifiers

    func testTempoModifierAssaiIntensifiesInTheTermDirection() {
        // "assai"/"molto" push in the term's own direction: a slow term slower, a fast term faster.
        XCTAssertEqual(parse(["Largo assai"]).tempoBPM, 46)          // 48 → slower
        XCTAssertEqual(parse(["Adagio molto"]).tempoBPM, 65)         // 68 → slower
        XCTAssertEqual(parse(["Allegro molto"]).tempoBPM, 146)       // 138 → faster
        XCTAssertEqual(parse(["Vivace assai"]).tempoBPM, 176)        // 166 → faster
    }

    func testTempoModifierNonTroppoPullsTowardModerate() {
        // "ma non troppo" damps toward a moderate tempo.
        XCTAssertEqual(parse(["Allegro non troppo"]).tempoBPM, 132)  // 138 → toward 112
        XCTAssertEqual(parse(["Allegro ma non troppo"]).tempoBPM, 132)
    }

    func testTempoModifierSostenutoPocoAndConBrio() {
        XCTAssertEqual(parse(["Andante sostenuto"]).tempoBPM, 86)    // held back → slower
        XCTAssertEqual(parse(["poco adagio"]).tempoBPM, 67)          // a little → mild nudge slower
        XCTAssertEqual(parse(["Allegro con brio"]).tempoBPM, 146)    // with spirit → faster end
        XCTAssertEqual(parse(["Andante con moto"]).tempoBPM, 98)     // with motion → faster
    }

    // MARK: - Dynamics and relative/mid-piece terms are never the starting tempo

    func testDynamicsAreNeverAStartingTempo() {
        XCTAssertNil(parse(["piano"]).tempoBPM)
        XCTAssertNil(parse(["forte"]).tempoBPM)
        XCTAssertNil(parse(["mezzo forte"]).tempoBPM)
        XCTAssertNil(parse(["pp"]).tempoBPM)
        XCTAssertNil(parse(["mf"]).tempoBPM)
    }

    func testRelativeMidPieceTermsAreNeverAStartingTempo() {
        XCTAssertNil(parse(["rit."]).tempoBPM)
        XCTAssertNil(parse(["ritardando"]).tempoBPM)
        XCTAssertNil(parse(["rall."]).tempoBPM)
        XCTAssertNil(parse(["accel."]).tempoBPM)
        XCTAssertNil(parse(["a tempo"]).tempoBPM)
        XCTAssertNil(parse(["più mosso"]).tempoBPM)
        XCTAssertNil(parse(["meno mosso"]).tempoBPM)
        XCTAssertNil(parse(["colla voce"]).tempoBPM)
    }

    // MARK: - Consecutive counting-run rejection

    func testConsecutiveCountingRunOnOneLineIsRejected() {
        // Penciled counting OCR'd as a single line: not a tempo (no cue) and not a meter.
        let result = parse(["1 2 3 4 5 6 7 8 9 10"])
        XCTAssertNil(result.tempoBPM)
        XCTAssertNil(result.timeSignature)
    }

    func testConsecutiveCountingRunAsBoxesDoesNotFabricateAMeter() {
        // Counting integers strung across a band must not be read as a stacked meter (e.g. 3-over-4),
        // while a genuine, separate stacked 3/4 at the first system is still found.
        let page = [
            line("1", 0.30, 0.75, 0.015, 0.02),
            line("2", 0.36, 0.75, 0.015, 0.02),
            line("3", 0.42, 0.75, 0.015, 0.02),
            line("4", 0.48, 0.75, 0.015, 0.02),
            line("5", 0.54, 0.75, 0.015, 0.02),
            line("3", 0.10, 0.60, 0.04, 0.05),   // real numerator …
            line("4", 0.10, 0.52, 0.04, 0.05),   // … over its denominator at the first system
        ]
        let result = SheetMusicOCRParser.parse(page)
        XCTAssertNil(result.tempoBPM, "counting integers carry no tempo cue")
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 3, denominator: 4),
                       "the real first-system 3/4 survives; the penciled 1-5 run is excluded")
    }

    // MARK: - Catalog codes and copyright years

    func testCatalogCodeIsNotTempoOrMeter() {
        let result = parse(["R 8039"])
        XCTAssertNil(result.tempoBPM)
        XCTAssertNil(result.timeSignature)
    }

    func testCopyrightYearIsNotTempoOrMeter() {
        XCTAssertNil(parse(["1963"]).tempoBPM)
        XCTAssertNil(parse(["1963"]).timeSignature)
        // A year that would otherwise mis-split into a fused meter ("2016" → "20/16") must be rejected.
        XCTAssertNil(parse(["2016"]).timeSignature)
        // A Roman-numeral year carries no digits, so it is inert on every path.
        XCTAssertNil(parse(["MCMLXIII"]).tempoBPM)
        XCTAssertNil(parse(["MCMLXIII"]).timeSignature)
    }

    // MARK: - Word tempo wins when the numeric cue is weak

    func testWordTempoWinsWhenNumericCueIsWeak() {
        // A loose "J" (no "=", no real glyph) is NOT a strong cue → the number is rejected and the word
        // wins…
        let weak = parse(["Andante", "J 100"])
        XCTAssertEqual(weak.tempoBPM, 92)
        XCTAssertEqual(weak.tempoWord, "Andante")
        // …but a real "♩ =" mark still beats the word.
        let strong = parse(["Andante", "♩ = 100"])
        XCTAssertEqual(strong.tempoBPM, 100)
        XCTAssertNil(strong.tempoWord)
    }

    // MARK: - Meter at the staff start

    func testBoxedRecitativeCommonTimeAtStaffStart() {
        // A lone "C" where a meter sits (left, upper) → common time.
        let result = SheetMusicOCRParser.parse([line("C", 0.09, 0.55, 0.03, 0.04)])
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 4, denominator: 4))
    }

    func testStackedTwelveEightIsCompoundAtStaffStart() {
        let result = SheetMusicOCRParser.parse([
            line("12", 0.09, 0.62, 0.05, 0.045),
            line("8",  0.10, 0.57, 0.03, 0.045),
        ])
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 12, denominator: 8))
        XCTAssertEqual(result.timeSignature?.isCompound, true)
        XCTAssertEqual(result.timeSignature?.beatsPerBar, 4)
    }
}
