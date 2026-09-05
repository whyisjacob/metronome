import XCTest
@testable import Metronome

/// The **self-activation contract** for the Groove controls, driven through the real `MetronomeViewModel`
/// from its DEFAULT state — the gap the shipped app violated.
///
/// The existing groove accuracy proofs (`SwingAccuracyTests`, `RhythmCellTests`) hard-code `.eighth` /
/// `.sixteenth` and build a `MetronomeConfiguration` directly, so they can't see that at the app's default
/// subdivision (`.quarter`) the swing slider and the cell picker were silently inert. These tests start from
/// `MetronomeViewModel()` exactly as the app launches and assert that:
///   * enabling swing auto-advances the subdivision to the coarsest grid swing can shape (eighths), and the
///     resulting `RenderPlan` — the very snapshot the audio thread reads — actually swings; and
///   * selecting a rhythm cell auto-advances to the sixteenth grid, and the plan silences exactly the cell's
///     non-sounding sixteenths.
/// A regression that made either control inert again (or that stopped the subdivision from moving) fails here.
///
/// Instantiating the view model touches no audio hardware: `MetronomeEngine.update` early-returns until an
/// offline/real sample rate is configured, so `setSwing`/`setCell` only mutate and publish `config`.
@MainActor
final class GrooveActivationTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Swing

    /// From the default quarter-note pulse, turning swing up must select the eighth grid and genuinely swing:
    /// the off-beat "and" (tick 1) is delayed past its straight ½-beat position, while the main beats stay put.
    func testEnablingSwingFromDefaultAutoAdvancesToEighthAndActuallySwings() {
        let vm = MetronomeViewModel()
        XCTAssertEqual(vm.subdivision, .quarter, "precondition: the app default is a straight quarter pulse")
        XCTAssertFalse(vm.swingIsAudible, "precondition: swing is inert at the default quarter grid")

        vm.setSwing(0.6)

        // (1) The control self-activated: the subdivision advanced to the grid swing needs, and — because
        //     `subdivision` is the published source of truth the main-screen picker binds to — the picker
        //     now shows eighths too.
        XCTAssertEqual(vm.subdivision, .eighth, "enabling swing must auto-select the eighth grid")
        XCTAssertEqual(vm.swing, 0.6, accuracy: 1e-9, "the requested swing amount is preserved")
        XCTAssertTrue(vm.swingIsAudible, "swing must now report itself as audible, not merely set")

        // (2) The resulting render plan — what the audio render thread reads — actually swings.
        let plan = RenderPlan(config: vm.config, sampleRate: sampleRate)
        XCTAssertEqual(plan.ticksPerBeat, 2, "eighth grid = two ticks per beat")

        let straightOffBeat = Int(plan.framesPerTick.rounded())     // straight tick 1 = round(1 × framesPerTick)
        let swungOffBeat = plan.frame(forTick: 1)
        XCTAssertGreaterThan(swungOffBeat, straightOffBeat,
            "the off-beat (tick 1) must be delayed past its straight position once swing is on")

        // The main beats never move: tick 0 stays at 0, and the next beat (tick 2) stays on the straight grid.
        XCTAssertEqual(plan.frame(forTick: 0), 0, "the downbeat (tick 0) must not move under swing")
        XCTAssertEqual(plan.frame(forTick: 2), Int((2 * plan.framesPerTick).rounded()),
            "the next main beat (tick 2) must stay on the straight grid")
    }

    /// Swing lives on the eighth/sixteenth grid, so reaching for it from a TRIPLET — an already-even 3s
    /// division that never swings — must also advance to eighths (the general "∉ {eighth, sixteenth}" rule).
    func testEnablingSwingFromTripletAutoAdvancesToEighth() {
        let vm = MetronomeViewModel()
        vm.setSubdivision(.triplet)
        XCTAssertEqual(vm.subdivision, .triplet)
        XCTAssertFalse(vm.swingIsAudible, "triplets do not swing")

        vm.setSwing(0.5)

        XCTAssertEqual(vm.subdivision, .eighth, "swing from a non-swinging triplet must advance to eighths")
        XCTAssertTrue(vm.swingIsAudible)
    }

    /// Self-activation must not fight an explicit choice: enabling swing while already on a swinging grid
    /// (sixteenths) must NOT knock the subdivision down to eighths, and returning swing to 0 must not revert
    /// the subdivision — only activation auto-advances.
    func testSwingActivationRespectsAnExistingSwingingGridAndNeverReverts() {
        let vm = MetronomeViewModel()

        vm.setSubdivision(.sixteenth)
        vm.setSwing(0.4)
        XCTAssertEqual(vm.subdivision, .sixteenth, "swing on an already-swinging grid must leave it unchanged")
        XCTAssertTrue(vm.swingIsAudible)

        vm.setSwing(0)
        XCTAssertEqual(vm.subdivision, .sixteenth, "turning swing off must not revert the subdivision")
        XCTAssertFalse(vm.swingIsAudible, "swing at 0 is straight again")
    }

    // MARK: - Rhythm cells

    /// From the default quarter-note pulse, selecting a cell must select the sixteenth grid and silence
    /// exactly the cell's non-sounding sub-positions in the render plan (gallop sounds [0, 2, 3], mutes 1).
    func testSelectingCellFromDefaultAutoAdvancesToSixteenthAndSilencesTheRightTicks() {
        let vm = MetronomeViewModel()
        XCTAssertEqual(vm.subdivision, .quarter, "precondition: the app default is a straight quarter pulse")
        XCTAssertFalse(vm.cellIsActive, "precondition: a cell is inert at the default quarter grid")

        vm.setCell(.gallop)

        // (1) The control self-activated: the subdivision advanced to the sixteenth grid cells require.
        XCTAssertEqual(vm.subdivision, .sixteenth, "selecting a cell must auto-select the sixteenth grid")
        XCTAssertEqual(vm.cell, .gallop, "the requested cell is preserved")
        XCTAssertTrue(vm.cellIsActive, "the cell must now report itself as active")

        // (2) The render plan silences exactly the gallop's non-sounding sixteenth (position 1) and sounds
        //     the downbeat (0) and the two trailing sixteenths (2, 3). A muted tick still advances the count,
        //     it just emits no click — so this is the audible figure, proven at the plan the engine reads.
        let plan = RenderPlan(config: vm.config, sampleRate: sampleRate)
        XCTAssertEqual(plan.ticksPerBeat, 4, "sixteenth grid = four ticks per beat")
        XCTAssertNotEqual(plan.accentLevel(forTick: 0), .muted, "gallop sounds the downbeat (pos 0)")
        XCTAssertEqual(plan.accentLevel(forTick: 1), .muted, "gallop silences pos 1")
        XCTAssertNotEqual(plan.accentLevel(forTick: 2), .muted, "gallop sounds pos 2")
        XCTAssertNotEqual(plan.accentLevel(forTick: 3), .muted, "gallop sounds pos 3")
    }

    /// Selecting "Off" (`.straight`) is not an activation, so it must NOT move the subdivision: a user
    /// clearing the pattern from, say, eighths stays on eighths.
    func testSelectingStraightCellDoesNotAdvanceTheSubdivision() {
        let vm = MetronomeViewModel()
        vm.setSubdivision(.eighth)

        vm.setCell(.straight)

        XCTAssertEqual(vm.subdivision, .eighth, "clearing the pattern (Off) must not change the grid")
        XCTAssertFalse(vm.cellIsActive)
    }
}
