import XCTest
@testable import Metronome

final class TapTempoTests: XCTestCase {

    func testNilForSingleTap() {
        XCTAssertNil(TapTempo.bpm(fromTaps: [1.0]))
        XCTAssertNil(TapTempo.bpm(fromTaps: []))
    }

    func testEvenTapsGiveExactBPM() {
        // 0.5 s intervals → 120 BPM.
        let bpm = TapTempo.bpm(fromTaps: [0.0, 0.5, 1.0, 1.5, 2.0])
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm!, 120, accuracy: 0.001)
    }

    func testOutlierIntervalDiscarded() {
        // Four 0.5 s intervals and one huge stray gap that must be dropped as an outlier.
        let bpm = TapTempo.bpm(fromTaps: [0.0, 0.5, 1.0, 5.0, 5.5, 6.0])
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm!, 120, accuracy: 1.0)
    }

    func testClampedToSupportedRange() {
        XCTAssertEqual(TapTempo.bpm(fromTaps: [0, 2, 4])!, 30, accuracy: 0.001)          // 30 BPM
        XCTAssertEqual(TapTempo.bpm(fromTaps: [0, 0.1, 0.2])!, 300, accuracy: 0.001)     // clamp 600→300
    }

    func testResetGapStartsFresh() {
        var t = TapTempo(maxIntervals: 6, resetGap: 2.0)
        XCTAssertNil(t.addTap(at: 0))
        XCTAssertEqual(t.addTap(at: 0.5)!, 120, accuracy: 0.001)
        // A gap longer than resetGap clears history → back to a single tap → nil.
        XCTAssertNil(t.addTap(at: 10))
    }

    func testRollingWindowStaysBounded() {
        var t = TapTempo(maxIntervals: 3)
        var last: Double?
        for i in 0..<10 { last = t.addTap(at: Double(i) * 0.5) }
        XCTAssertNotNil(last)
        XCTAssertEqual(last!, 120, accuracy: 0.001)
        XCTAssertLessThanOrEqual(t.taps.count, 4)   // maxIntervals + 1 timestamps
    }

    func testAccelerandoTracksUpward() {
        // Shrinking intervals: the estimate should end well above the starting tempo.
        let taps: [Double] = [0.0, 0.6, 1.15, 1.65, 2.10, 2.50]
        let bpm = TapTempo.bpm(fromTaps: taps)
        XCTAssertNotNil(bpm)
        XCTAssertGreaterThan(bpm!, 100)
    }
}
