import XCTest
@testable import Metronome

/// The main-screen time-signature control is a roll-to-select pair of wheels: a numerator (beats-per-bar)
/// wheel and a denominator (beat-unit) wheel. Their option lists are `TimeSignature`'s own validation
/// constants (`numeratorRange`, `allowedDenominators`), so a value you can roll to is always a meter the
/// model accepts — a meter you dial in is never silently clamped, and the wheels can't drift out of sync
/// with `TimeSignature`'s validation.
final class MeterRollerTests: XCTestCase {

    func testNumeratorWheelSpansOneToThirtyTwoInclusively() {
        XCTAssertEqual(TimeSignature.numeratorRange.lowerBound, 1)
        XCTAssertEqual(TimeSignature.numeratorRange.upperBound, 32)
        XCTAssertEqual(Array(TimeSignature.numeratorRange).count, 32)
    }

    func testDenominatorWheelOffersTheMusicalNoteValues() {
        XCTAssertEqual(TimeSignature.allowedDenominators, [2, 4, 8, 16])
    }

    /// Every numerator the wheel can land on survives `TimeSignature` validation unchanged.
    func testEveryNumeratorOnTheWheelIsAcceptedUnchanged() {
        for n in TimeSignature.numeratorRange {
            let ts = TimeSignature(numerator: n, denominator: 4)
            XCTAssertEqual(ts.numerator, n, "numerator \(n) was clamped by TimeSignature")
        }
    }

    /// Every denominator the wheel can land on survives `TimeSignature` validation unchanged.
    func testEveryDenominatorOnTheWheelIsAcceptedUnchanged() {
        for d in TimeSignature.allowedDenominators {
            let ts = TimeSignature(numerator: 4, denominator: d)
            XCTAssertEqual(ts.denominator, d, "denominator \(d) was rejected by TimeSignature")
        }
    }

    /// Every (numerator, denominator) pair the two wheels can jointly produce is a valid meter the model
    /// preserves exactly — so rolling to e.g. 7/8 or 5/4 or 12/8 can never be silently rewritten.
    func testEveryWheelCombinationRoundTripsThroughTheModel() {
        for n in TimeSignature.numeratorRange {
            for d in TimeSignature.allowedDenominators {
                let ts = TimeSignature(numerator: n, denominator: d)
                XCTAssertEqual(ts.numerator, n)
                XCTAssertEqual(ts.denominator, d)
                XCTAssertEqual(ts.displayString, "\(n)/\(d)")
            }
        }
    }

    /// Values just beyond the wheels' ends are outside the option lists, and the model clamps/normalises
    /// them back to the bounds the wheels stop at — the roller can't express an out-of-range meter.
    func testMetersBeyondTheWheelEndsClampToItsBounds() {
        XCTAssertFalse(TimeSignature.numeratorRange.contains(0))
        XCTAssertFalse(TimeSignature.numeratorRange.contains(33))
        XCTAssertFalse(TimeSignature.allowedDenominators.contains(1))
        XCTAssertFalse(TimeSignature.allowedDenominators.contains(32))
        XCTAssertEqual(TimeSignature(numerator: 0, denominator: 4).numerator, 1)     // below → 1
        XCTAssertEqual(TimeSignature(numerator: 99, denominator: 4).numerator, 32)   // above → 32
        XCTAssertEqual(TimeSignature(numerator: 4, denominator: 3).denominator, 4)   // non-musical → 4
    }
}
