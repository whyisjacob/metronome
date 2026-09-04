import XCTest
@testable import Metronome

/// Verifies the SmartImport view model's recognise→parse→seed orchestration: given recognised OCR lines,
/// it parses them (via the pure `SheetMusicOCRParser`) and seeds its **editable** review fields — tempo,
/// numerator, denominator — plus the stage, so the review UI shows values the user can confirm or correct.
///
/// This exercises everything except Vision itself (which needs a device/simulator + a real image); the
/// `ingest(recognizedLines:)` seam lets the whole path be tested deterministically in CI.
@MainActor
final class SmartImportViewModelTests: XCTestCase {

    func testIngestSeedsEditableFieldsFromDetectedTempoAndMeter() {
        let vm = SmartImportViewModel()
        vm.ingest(recognizedLines: ["Allegro", "♩ = 132", "3/4"])

        XCTAssertEqual(vm.stage, .review)
        XCTAssertEqual(vm.tempoBPM, 132)              // explicit number preferred over the word
        XCTAssertEqual(vm.numerator, 3)
        XCTAssertEqual(vm.denominator, 4)
        XCTAssertEqual(vm.timeSignature, TimeSignature(numerator: 3, denominator: 4))
        XCTAssertTrue(vm.foundSomething)
    }

    func testIngestSeedsTempoFromWordWhenNoNumber() {
        let vm = SmartImportViewModel()
        vm.ingest(recognizedLines: ["Presto", "6/8"])

        XCTAssertEqual(vm.tempoBPM, 184)
        XCTAssertEqual(vm.numerator, 6)
        XCTAssertEqual(vm.denominator, 8)
        XCTAssertEqual(vm.timeSignature, TimeSignature(numerator: 6, denominator: 8))
    }

    func testIngestClampsSeededTempoToEngineRange() {
        let vm = SmartImportViewModel()
        vm.ingest(recognizedLines: ["♩ = 400"])       // above the engine's 30…300 range
        XCTAssertEqual(vm.tempoBPM, 300)               // seeded field is clamped so it can't be out of range
    }

    func testIngestWithNoDetectionKeepsDefaultsAndFlagsEmpty() {
        let vm = SmartImportViewModel()
        vm.ingest(recognizedLines: ["just some lyrics, no marks"])

        XCTAssertEqual(vm.stage, .review)
        XCTAssertFalse(vm.foundSomething)              // review UI shows the "enter it yourself" note
        XCTAssertEqual(vm.tempoBPM, 120)               // unchanged defaults, ready for manual entry
        XCTAssertEqual(vm.numerator, 4)
        XCTAssertEqual(vm.denominator, 4)
    }

    func testResetReturnsToChooser() {
        let vm = SmartImportViewModel()
        vm.ingest(recognizedLines: ["4/4"])
        XCTAssertEqual(vm.stage, .review)

        vm.reset()
        XCTAssertEqual(vm.stage, .chooser)
        XCTAssertNil(vm.result)
    }
}
