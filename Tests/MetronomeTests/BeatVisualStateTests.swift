import XCTest
@testable import Metronome

/// The pure logic behind the beat indicators: the subdivision-phase reducer (the only stateful bit that
/// decides how the ring/dots/counter show the "e / and / a" pulses) and the bounds-safe accent lookup.
final class BeatVisualStateTests: XCTestCase {

    func testSubdivisionPhaseResetsOnBeat() {
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 3, wasBeat: true, ticksPerBeat: 4), 0)
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 0, wasBeat: true, ticksPerBeat: 1), 0)
    }

    func testSubdivisionPhaseAdvancesBetweenBeats() {
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 0, wasBeat: false, ticksPerBeat: 4), 1)
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 1, wasBeat: false, ticksPerBeat: 4), 2)
    }

    func testSubdivisionPhaseCapsAtTicksPerBeatMinusOne() {
        // Never runs past the last subdivision even if an extra sub-click somehow arrives.
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 3, wasBeat: false, ticksPerBeat: 4), 3)
        // Quarter (no subdivisions): phase is pinned at 0.
        XCTAssertEqual(BeatVisualState.nextSubdivisionPhase(previous: 0, wasBeat: false, ticksPerBeat: 1), 0)
    }

    /// One bar of 4/4 sixteenths: the phase walks 0 → 1 → 2 → 3 within each beat and resets on the next.
    func testWalkThroughOneBeatOfSixteenths() {
        let tpb = 4
        var phase = BeatVisualState.nextSubdivisionPhase(previous: 0, wasBeat: true, ticksPerBeat: tpb)
        XCTAssertEqual(phase, 0)
        for expected in [1, 2, 3] {
            phase = BeatVisualState.nextSubdivisionPhase(previous: phase, wasBeat: false, ticksPerBeat: tpb)
            XCTAssertEqual(phase, expected)
        }
        phase = BeatVisualState.nextSubdivisionPhase(previous: phase, wasBeat: true, ticksPerBeat: tpb)
        XCTAssertEqual(phase, 0, "the next beat resets the phase")
    }

    /// Even tuplets (5 / 6 / 7 ticks per beat) walk the subdivision phase 0…tpb-1 and cap there. This is
    /// exactly what drives the ring/dots to render the tuplet ticks: both `SubdivisionPips` and the ring's
    /// `subdivisionSlots` iterate `0..<ticksPerBeat`, so a correct phase walk means the tuplet clicks are
    /// drawn and lit in step with the audio.
    func testSubdivisionPhaseWalksThroughTuplets() {
        for tpb in [5, 6, 7] {
            var phase = BeatVisualState.nextSubdivisionPhase(previous: 0, wasBeat: true, ticksPerBeat: tpb)
            XCTAssertEqual(phase, 0, "tuplet \(tpb): a beat resets the phase")
            for expected in 1..<tpb {
                phase = BeatVisualState.nextSubdivisionPhase(previous: phase, wasBeat: false, ticksPerBeat: tpb)
                XCTAssertEqual(phase, expected, "tuplet \(tpb): phase should advance to \(expected)")
            }
            // An extra sub-click never runs past the last tuplet tick…
            phase = BeatVisualState.nextSubdivisionPhase(previous: phase, wasBeat: false, ticksPerBeat: tpb)
            XCTAssertEqual(phase, tpb - 1, "tuplet \(tpb): phase caps at ticksPerBeat-1")
            // …and the next beat resets it.
            phase = BeatVisualState.nextSubdivisionPhase(previous: phase, wasBeat: true, ticksPerBeat: tpb)
            XCTAssertEqual(phase, 0)
        }
    }

    func testIdleStateIsNotPlaying() {
        let s = BeatVisualState.idle()
        XCTAssertFalse(s.isPlaying)
        XCTAssertNil(s.currentBeat)
        XCTAssertEqual(s.beatsPerMeasure, 4)
    }

    func testIsAccentedIsBoundsSafe() {
        let s = BeatVisualState(beatsPerMeasure: 3, ticksPerBeat: 1, accents: [true, false, false],
                                currentBeat: 0, subdivisionPhase: 0, accentLevel: .strong, flashID: 1,
                                isPlaying: true, isOnBeat: true)
        XCTAssertTrue(s.isAccented(0))
        XCTAssertFalse(s.isAccented(1))
        XCTAssertFalse(s.isAccented(99))   // out of range → false, never a crash
        XCTAssertFalse(s.isAccented(-1))
    }
}
