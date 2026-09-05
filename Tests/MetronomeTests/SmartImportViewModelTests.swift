import XCTest
import CoreGraphics
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

    /// A photo that can't be loaded at all lands on a *visible* failure stage (not silence), so the UI can
    /// show an error + retry rather than appearing to do nothing.
    func testFailedToLoadImageShowsAVisibleErrorStage() {
        let vm = SmartImportViewModel()
        vm.failedToLoadImage()

        guard case .failed(let message) = vm.stage else {
            return XCTFail("expected a visible .failed stage, got \(vm.stage)")
        }
        XCTAssertFalse(message.isEmpty, "the failure stage must carry a user-facing message")
        XCTAssertNil(vm.result)
    }

    func testRetryFromFailedReturnsToChooser() {
        let vm = SmartImportViewModel()
        vm.failedToLoadImage()
        guard case .failed = vm.stage else { return XCTFail("expected .failed") }

        vm.reset()   // the failure view's "Try again"
        XCTAssertEqual(vm.stage, .chooser)
        XCTAssertNil(vm.result)
    }

    /// The geometry-aware ingest path: a stacked numerator/denominator (no slash) is detected from the
    /// boxes, an Italian tempo word is read, and the raw recognised text is exposed for the review screen.
    func testIngestGeometryLinesDetectsStackedMeterAndRecordsRawText() {
        let vm = SmartImportViewModel()
        let lines = [
            RecognizedTextLine(text: "Allegro", boundingBox: CGRect(x: 0.30, y: 0.85, width: 0.20, height: 0.05)),
            RecognizedTextLine(text: "3", boundingBox: CGRect(x: 0.10, y: 0.60, width: 0.04, height: 0.05)),
            RecognizedTextLine(text: "4", boundingBox: CGRect(x: 0.10, y: 0.52, width: 0.04, height: 0.05)),
        ]
        vm.ingest(lines)

        XCTAssertEqual(vm.stage, .review)
        XCTAssertEqual(vm.numerator, 3)
        XCTAssertEqual(vm.denominator, 4)
        XCTAssertEqual(vm.tempoBPM, 138)                       // "Allegro"
        XCTAssertTrue(vm.foundSomething)
        XCTAssertTrue(vm.recognizedText.contains("Allegro"))   // surfaced as "what we read"
    }
}
