import XCTest
@testable import Metronome

/// Unit tests for the pure OCR-parsing logic (`SheetMusicOCRParser.parse`), which turns the strings Vision
/// recognises on a photo of a score into a best-effort starting tempo + time signature. No camera, no
/// image, no Vision — just recognised-text strings in, a `SheetMusicImportResult` out — so the whole
/// extraction is verifiable in CI. These are the canonical examples from the feature spec plus edges.
final class SheetMusicOCRParserTests: XCTestCase {

    private func parse(_ lines: [String]) -> SheetMusicImportResult {
        SheetMusicOCRParser.parse(recognizedLines: lines)
    }

    // MARK: - Tempo: explicit numeric metronome marks

    func testQuarterNoteEqualsNumber() {
        XCTAssertEqual(parse(["♩ = 132"]).tempoBPM, 132)
        XCTAssertEqual(parse(["♩ = 120"]).tempoBPM, 120)
    }

    func testNumericMarkVariants() {
        XCTAssertEqual(parse(["♩=120"]).tempoBPM, 120)        // no spaces
        XCTAssertEqual(parse(["=120"]).tempoBPM, 120)          // bare equals (glyph OCR'd away)
        XCTAssertEqual(parse(["M.M. ♩ = 88"]).tempoBPM, 88)    // Mälzel prefix
        XCTAssertEqual(parse(["♩ 96"]).tempoBPM, 96)           // glyph, no equals
    }

    func testTempoRangeTakesFirstNumber() {
        // A tempo range "120–132" resolves to the first (lower) number.
        XCTAssertEqual(parse(["♩ = 120-132"]).tempoBPM, 120)
    }

    func testImplausibleNumbersAreNotTempo() {
        // A stray "= 8" (too small) and a page number must not be read as a tempo.
        let result = parse(["Page 4", "= 8"])
        XCTAssertNil(result.tempoBPM)
    }

    func testLowAndHighEndsWithinRange() {
        XCTAssertEqual(parse(["♩ = 40"]).tempoBPM, 40)
        XCTAssertEqual(parse(["♩ = 208"]).tempoBPM, 208)
    }

    // MARK: - Tempo: Italian words (fallback when no number)

    func testItalianTempoWords() {
        // Representative teaching BPMs from the expanded tempo table (base absolute terms).
        XCTAssertEqual(parse(["Largo"]).tempoBPM, 48)
        XCTAssertEqual(parse(["Adagio"]).tempoBPM, 68)
        XCTAssertEqual(parse(["Andante"]).tempoBPM, 92)
        XCTAssertEqual(parse(["Moderato"]).tempoBPM, 112)
        XCTAssertEqual(parse(["Allegro"]).tempoBPM, 138)
        XCTAssertEqual(parse(["Vivace"]).tempoBPM, 166)
        XCTAssertEqual(parse(["Presto"]).tempoBPM, 184)
    }

    func testTempoWordIsReportedForDisplay() {
        let result = parse(["Allegro"])
        XCTAssertEqual(result.tempoBPM, 138)
        XCTAssertEqual(result.tempoWord, "Allegro")
    }

    func testTempoWordCaseInsensitiveAndEmbedded() {
        XCTAssertEqual(parse(["allegro"]).tempoBPM, 138)
        XCTAssertEqual(parse(["ALLEGRO"]).tempoBPM, 138)
        XCTAssertEqual(parse(["Allegro con brio"]).tempoBPM, 146)   // 'con brio' nudges toward the fast end
        XCTAssertEqual(parse(["Allegro,"]).tempoBPM, 138)           // trailing punctuation
    }

    func testExplicitNumberPreferredOverWord() {
        // "prefer an explicit number": the word is present but a number wins, and no word is reported.
        let result = parse(["Allegro", "♩ = 100"])
        XCTAssertEqual(result.tempoBPM, 100)
        XCTAssertNil(result.tempoWord)
    }

    // MARK: - Time signature: explicit N/M

    func testCommonTimeSignatures() {
        XCTAssertEqual(parse(["4/4"]).timeSignature, TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(parse(["3/4"]).timeSignature, TimeSignature(numerator: 3, denominator: 4))
        XCTAssertEqual(parse(["6/8"]).timeSignature, TimeSignature(numerator: 6, denominator: 8))
        XCTAssertEqual(parse(["2/2"]).timeSignature, TimeSignature(numerator: 2, denominator: 2))
        XCTAssertEqual(parse(["12/8"]).timeSignature, TimeSignature(numerator: 12, denominator: 8))
    }

    func testTimeSignatureWithSpacesAroundSlash() {
        XCTAssertEqual(parse(["3 / 4"]).timeSignature, TimeSignature(numerator: 3, denominator: 4))
    }

    func testSixEightIsCompound() {
        let ts = parse(["6/8"]).timeSignature
        XCTAssertEqual(ts?.beatsPerBar, 2)       // felt in 2 dotted-quarter groups
        XCTAssertEqual(ts?.isCompound, true)
    }

    func testDisallowedDenominatorRejected() {
        // "5/7" is not a real meter (denominator not a note value): don't fabricate one.
        let result = parse(["Andante", "5/7"])
        XCTAssertNil(result.timeSignature)
        XCTAssertEqual(result.tempoBPM, 92)      // the tempo word is still read
    }

    // MARK: - Time signature: common / cut time

    func testCommonTimeSymbol() {
        XCTAssertEqual(parse(["C"]).timeSignature, TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(parse(["Common time"]).timeSignature, TimeSignature(numerator: 4, denominator: 4))
    }

    func testCutTimeSymbol() {
        XCTAssertEqual(parse(["¢"]).timeSignature, TimeSignature(numerator: 2, denominator: 2))
        XCTAssertEqual(parse(["Cut time"]).timeSignature, TimeSignature(numerator: 2, denominator: 2))
    }

    func testNumericMeterPreferredOverLetterC() {
        // If both a "C" and an explicit "3/4" appear, the explicit numeric meter wins.
        XCTAssertEqual(parse(["C", "3/4"]).timeSignature, TimeSignature(numerator: 3, denominator: 4))
    }

    // MARK: - Combined & empty

    func testRealisticHeaderLines() {
        let result = parse(["Sonata No. 14", "Allegro", "♩ = 120", "4/4"])
        XCTAssertEqual(result.tempoBPM, 120)
        XCTAssertNil(result.tempoWord)           // number present → no word reported
        XCTAssertEqual(result.timeSignature, TimeSignature(numerator: 4, denominator: 4))
        XCTAssertTrue(result.hasAnyDetection)
    }

    func testNothingDetected() {
        let result = parse(["Verse 1", "the quick brown fox"])
        XCTAssertNil(result.tempoBPM)
        XCTAssertNil(result.timeSignature)
        XCTAssertFalse(result.hasAnyDetection)
    }

    func testEmptyInput() {
        let result = parse([])
        XCTAssertEqual(result, .empty)
        XCTAssertFalse(result.hasAnyDetection)
    }
}
