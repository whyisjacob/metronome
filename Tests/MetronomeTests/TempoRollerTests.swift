import XCTest
@testable import Metronome

/// The main-screen BPM roller (a roll-to-select number wheel) offers exactly the tempos the engine
/// accepts: its values are derived from `MetronomeConfiguration.tempoRange`, so a value you can roll to is
/// always a value the engine will honour — a selection is never silently clamped, and the wheel can never
/// drift out of sync with the tempo clamp.
final class TempoRollerTests: XCTestCase {

    func testSelectableTemposSpanTheTempoRangeInclusively() {
        let tempos = MetronomeConfiguration.selectableTempos
        XCTAssertEqual(tempos.first, Int(MetronomeConfiguration.tempoRange.lowerBound))
        XCTAssertEqual(tempos.last, Int(MetronomeConfiguration.tempoRange.upperBound))
        XCTAssertEqual(tempos.first, 30)
        XCTAssertEqual(tempos.last, 300)
    }

    func testSelectableTemposAreEveryIntegerStepSortedAndUnique() {
        let tempos = MetronomeConfiguration.selectableTempos
        XCTAssertEqual(tempos.count, 300 - 30 + 1)           // 271 discrete values
        XCTAssertEqual(tempos, tempos.sorted())              // ascending, as the wheel reads top → bottom
        XCTAssertEqual(Set(tempos).count, tempos.count)      // no duplicates
        for (a, b) in zip(tempos, tempos.dropFirst()) {
            XCTAssertEqual(b - a, 1, "roller steps must be exactly 1 BPM apart")
        }
    }

    /// Every value the roller can land on survives the configuration clamp unchanged — so rolling can
    /// never select a tempo the engine would quietly move underneath the user.
    func testEverySelectableTempoIsAcceptedUnchangedByTheConfig() {
        for bpm in MetronomeConfiguration.selectableTempos {
            let config = MetronomeConfiguration(bpm: Double(bpm))
            XCTAssertEqual(config.bpm, Double(bpm), "roller value \(bpm) was clamped by the config")
        }
    }

    /// The roller cannot express out-of-range tempos, and the config clamps anything beyond the ends back
    /// to exactly the bounds the wheel stops at.
    func testTemposBeyondTheRollerEndsClampToItsBounds() {
        XCTAssertFalse(MetronomeConfiguration.selectableTempos.contains(29))
        XCTAssertFalse(MetronomeConfiguration.selectableTempos.contains(301))
        XCTAssertEqual(MetronomeConfiguration(bpm: 10).bpm, 30)
        XCTAssertEqual(MetronomeConfiguration(bpm: 500).bpm, 300)
    }
}
