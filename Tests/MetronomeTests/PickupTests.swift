import XCTest
@testable import Metronome

/// Pure, deterministic tests for the pickup / count-in **theory** — no audio engine. Expected counts are
/// written out by hand from the musical spec (a pickup is the bar's TAIL: it counts beats `N−k+1 … N`,
/// then the strong downbeat "1"), never derived from the code under test. Because the implementation just
/// runs the existing per-tick machinery on a shifted `extendedTick`, these also pin the sub-beat and
/// compound cases. Sample-accurate placement (incl. swing) is proven on real audio in
/// `PickupRenderAccuracyTests`, but the swing *frame* math is also checked here from first principles.
///
/// `@MainActor` because one case drives `MetronomeViewModel` (a `@MainActor` type); the pure `RenderPlan`
/// cases are unaffected by running on the main actor.
@MainActor
final class PickupTests: XCTestCase {

    private let sr = 48_000.0

    private func plan(_ ts: TimeSignature, _ sub: Subdivision, ticks: Int, bpm: Double = 120) -> RenderPlan {
        RenderPlan(config: MetronomeConfiguration(bpm: bpm, timeSignature: ts, subdivision: sub),
                   sampleRate: sr, pickup: Pickup(ticks: ticks))
    }

    /// (c) Whole-beat pickups count the TAIL of the bar then the strong downbeat, for every required meter.
    /// Main-beat (quarter) subdivision → 1 tick per beat, so a k-beat pickup is k ticks.
    func testWholeBeatPickupCountsTailOfBarThenStrongDownbeat() {
        struct C { let n: Int; let d: Int; let k: Int; let counts: [Int] }
        let cases: [C] = [
            C(n: 4,  d: 4, k: 1, counts: [4]),
            C(n: 4,  d: 4, k: 2, counts: [3, 4]),
            C(n: 4,  d: 4, k: 3, counts: [2, 3, 4]),
            C(n: 3,  d: 4, k: 1, counts: [3]),
            C(n: 3,  d: 4, k: 2, counts: [2, 3]),
            C(n: 2,  d: 4, k: 1, counts: [2]),
            C(n: 2,  d: 2, k: 1, counts: [2]),          // cut time — counts in 2
            C(n: 6,  d: 8, k: 1, counts: [2]),          // compound: 2 dotted-quarter beats
            C(n: 12, d: 8, k: 1, counts: [4]),          // compound: 4 dotted-quarter beats
            C(n: 12, d: 8, k: 2, counts: [3, 4]),
        ]
        for c in cases {
            let ts = TimeSignature(numerator: c.n, denominator: c.d)
            let p = plan(ts, .quarter, ticks: c.k)     // quarter → 1 tick/beat, so ticks == beats here
            let label = "\(c.n)/\(c.d) k=\(c.k)"
            for (j, count) in c.counts.enumerated() {
                XCTAssertTrue(p.isPickup(forTick: j), "\(label): tick \(j) should be a pickup")
                XCTAssertEqual(p.voiceToken(forTick: j), .number(count - 1), "\(label): pickup \(j) counts \(count)")
                XCTAssertEqual(p.beatIndex(forTick: j), count - 1, "\(label): pickup \(j) visual index")
                XCTAssertNotEqual(p.accentLevel(forTick: j), .strong, "\(label): a pickup is never the strong accent")
            }
            let downTick = c.k
            XCTAssertFalse(p.isPickup(forTick: downTick), "\(label): the downbeat is not a pickup")
            XCTAssertEqual(p.voiceToken(forTick: downTick), .number(0), "\(label): the downbeat counts 1")
            XCTAssertEqual(p.accentLevel(forTick: downTick), .strong, "\(label): first real beat is STRONG")
        }
    }

    /// Sub-beat pickups — the very common real-world case, free because it's tick-denominated. These tokens
    /// come straight from the existing `voiceToken` via the shifted tick.
    func testSubBeatPickupsSpeakTheRightSyllable() {
        // Eighth grid, 1 tick → the "& of 4" in 4/4.
        let eighth = plan(.common, .eighth, ticks: 1)
        XCTAssertEqual(eighth.voiceToken(forTick: 0), .syllable(.and), "eighth 1-tick pickup = the '& of 4'")
        XCTAssertEqual(eighth.voiceToken(forTick: 1), .number(0), "then the downbeat '1'")

        // Sixteenth grid: 1 tick → "a"; 2 ticks → "and, a".
        let sixteenth1 = plan(.common, .sixteenth, ticks: 1)
        XCTAssertEqual(sixteenth1.voiceToken(forTick: 0), .syllable(.a))
        let sixteenth2 = plan(.common, .sixteenth, ticks: 2)
        XCTAssertEqual(sixteenth2.voiceToken(forTick: 0), .syllable(.and))
        XCTAssertEqual(sixteenth2.voiceToken(forTick: 1), .syllable(.a))
        XCTAssertEqual(sixteenth2.voiceToken(forTick: 2), .number(0))

        // Triplet grid, 1 tick → "let".
        let triplet = plan(.common, .triplet, ticks: 1)
        XCTAssertEqual(triplet.voiceToken(forTick: 0), .syllable(.letSub))

        // Compound: a single EIGHTH pickup in 6/8 speaks "let" (internally consistent — see A0).
        let compound = plan(TimeSignature(numerator: 6, denominator: 8), .eighth, ticks: 1)
        XCTAssertEqual(compound.voiceToken(forTick: 0), .syllable(.letSub), "6/8 single-eighth pickup → 'let'")
    }

    /// (b) The pickup inherits the bar's real TAIL accents — a group head that falls inside the pickup keeps
    /// its `medium` — and the pickup is never `strong`; the first real downbeat is `strong`.
    func testPickupInheritsTailAccentsAndNeverStrong() {
        // 4/4 default accents [strong, normal, medium, normal]. A 2-beat pickup counts "3, 4": beat 3 is
        // the mid-bar secondary accent (medium), beat 4 normal.
        let p = plan(.common, .quarter, ticks: 2)
        XCTAssertEqual(p.accentLevel(forTick: 0), .medium, "the '3' pickup keeps 4/4's mid-bar medium accent")
        XCTAssertEqual(p.accentLevel(forTick: 1), .normal, "the '4' pickup is normal")
        XCTAssertEqual(p.accentLevel(forTick: 2), .strong, "the downbeat is strong")

        // 7/8 as 2+2+3: accents [strong, normal, medium, normal, medium, normal, normal]. On the main-beat
        // grid (1 tick/beat), a 5-beat pickup (counts 3…7) spans TWO group heads (beats 3 and 5) — both must
        // stay medium, none strong.
        let seven = plan(TimeSignature(numerator: 7, denominator: 8), .quarter, ticks: 5)
        XCTAssertEqual(seven.voiceToken(forTick: 0), .number(2), "7/8 pickup starts on the count '3'")
        XCTAssertEqual(seven.accentLevel(forTick: 0), .medium, "7/8 pickup: the beat-3 group head stays medium")
        XCTAssertEqual(seven.accentLevel(forTick: 2), .medium, "7/8 pickup: the beat-5 group head stays medium")
        for j in 0..<5 { XCTAssertNotEqual(seven.accentLevel(forTick: j), .strong, "no pickup tick is strong") }
        XCTAssertEqual(seven.accentLevel(forTick: 5), .strong, "the downbeat after the 7/8 pickup is strong")
    }

    /// (d) The pickup plays ONCE: only the first `ticks` playback ticks are pickups; every beat after the
    /// first downbeat is a normal loop beat, and downbeats recur every bar.
    func testPickupPlaysOnce() {
        let ticks = 2
        let p = plan(.common, .quarter, ticks: ticks)   // 4/4
        XCTAssertTrue(p.isPickup(forTick: 0))
        XCTAssertTrue(p.isPickup(forTick: 1))
        for t in ticks..<(ticks + 4 * 4) {
            XCTAssertFalse(p.isPickup(forTick: t), "tick \(t) must NOT be a pickup — the lead-in plays once")
        }
        for t in stride(from: ticks, through: ticks + 3 * 4, by: 4) {
            XCTAssertEqual(p.accentLevel(forTick: t), .strong, "bar downbeat at tick \(t) must be strong")
            XCTAssertEqual(p.beatIndex(forTick: t), 0)
        }
    }

    /// Swing frame math from first principles: a full-swing eighth "& of 4" pickup sits LATE (⅔ of the
    /// beat), so it is only ⅓ of a beat before the downbeat — the pickup rides `SwingGrid` for free.
    func testSwungPickupAndOfFourSitsLate() {
        func plan(_ swing: Double) -> RenderPlan {
            RenderPlan(config: MetronomeConfiguration(bpm: 120, timeSignature: .common,
                                                      subdivision: .eighth, swing: swing),
                       sampleRate: sr, pickup: Pickup(ticks: 1))
        }
        // 120 BPM @ 48 kHz: framesPerTick 12000 (eighth), framesPerBeat 24000. Playback starts at frame 0.
        let straight = plan(0)
        XCTAssertEqual(straight.frame(forTick: 0), 0, "playback starts on the first pickup tick at frame 0")
        XCTAssertEqual(straight.frame(forTick: 1) - straight.frame(forTick: 0), 12000,
                       "straight: the '& of 4' is a full eighth (12000) before the downbeat")

        let full = plan(1.0)
        XCTAssertEqual(full.frame(forTick: 0), 0)
        XCTAssertEqual(full.frame(forTick: 1) - full.frame(forTick: 0), 8000,
                       "full swing: the '& of 4' sits at ⅔, so it is only ⅓ beat (8000) before the downbeat")
        XCTAssertEqual(full.voiceToken(forTick: 0), .syllable(.and), "the swung pickup is still the '&'")
    }

    /// With no pickup, `RenderPlan` is byte-for-byte its old self — the labeling and frame helpers match the
    /// pure config exactly (this is what keeps every existing accuracy/equality test valid).
    func testNoPickupMatchesPlainConfig() {
        let config = MetronomeConfiguration(bpm: 137, timeSignature: TimeSignature(numerator: 5, denominator: 8),
                                            subdivision: .triplet, swing: 0.4)
        let plain = RenderPlan(config: config, sampleRate: sr)                 // pickup defaults to .none
        for n in 0...600 {
            XCTAssertEqual(plain.frame(forTick: n), config.frame(forTick: n, sampleRate: sr), "frame \(n)")
            XCTAssertEqual(plain.accentLevel(forTick: n), config.accentLevel(forTick: n), "accent \(n)")
            XCTAssertEqual(plain.beatIndex(forTick: n), config.beatIndex(forTick: n), "beat \(n)")
            XCTAssertFalse(plain.isPickup(forTick: n), "no pickup → no pickup ticks")
        }
    }

    // MARK: - Pickup value type

    func testPickupExtendedTickShiftsToTheBarTail() {
        // 4/4 quarter → ticksPerBar 4. A 2-tick pickup starts on bar tick 2, so playback tick 0 → 2, and
        // the downbeat (playback tick 2) → extended tick 4 (bar tick 0 of the next bar).
        let p = Pickup(ticks: 2)
        XCTAssertEqual(p.startTick(ticksPerBar: 4), 2)
        XCTAssertEqual(p.extendedTick(0, ticksPerBar: 4), 2)
        XCTAssertEqual(p.extendedTick(2, ticksPerBar: 4), 4)
        XCTAssertTrue(p.isPickupTick(0, ticksPerBar: 4))
        XCTAssertTrue(p.isPickupTick(1, ticksPerBar: 4))
        XCTAssertFalse(p.isPickupTick(2, ticksPerBar: 4))
    }

    func testPickupEffectiveTicksClampsToIncompleteBar() {
        // A pickup is never a whole bar or more: 4 ticks in a 4-tick bar clamps to 3; a 1-tick bar → 0.
        XCTAssertEqual(Pickup(ticks: 4).effectiveTicks(ticksPerBar: 4), 3)
        XCTAssertEqual(Pickup(ticks: 99).effectiveTicks(ticksPerBar: 4), 3)
        XCTAssertEqual(Pickup(ticks: 1).effectiveTicks(ticksPerBar: 1), 0)
        XCTAssertEqual(Pickup(ticks: 0).effectiveTicks(ticksPerBar: 4), 0)
        // Disabled → extendedTick is the identity (no shift).
        XCTAssertEqual(Pickup.none.extendedTick(5, ticksPerBar: 4), 5)
    }

    // MARK: - (e) Clamping to the grid (view model)

    func testPickupClampsToGridOnMeterAndSubdivisionChange() {
        let vm = MetronomeViewModel()          // default 4/4 quarter → ticksPerBar 4 → max pickup 3
        vm.setPickupTicks(3)
        XCTAssertEqual(vm.pickupTicks, 3)
        vm.setPickupTicks(99)                   // clamps to the grid max
        XCTAssertEqual(vm.pickupTicks, 3)

        vm.setNumerator(2)                      // 2/4 → ticksPerBar 2 → max 1
        XCTAssertEqual(vm.maxPickupTicks, 1)
        XCTAssertEqual(vm.pickupTicks, 1, "the count-in must re-clamp when the bar gets shorter")

        // A finer subdivision GROWS ticksPerBar, so the clamped value survives and more room opens up.
        vm.setNumerator(4)                      // back to 4/4 quarter (ticksPerBar 4)
        vm.setPickupTicks(3)
        vm.setSubdivision(.sixteenth)           // ticksPerBar 16 → max 15
        XCTAssertEqual(vm.maxPickupTicks, 15)
        XCTAssertEqual(vm.pickupTicks, 3, "a finer grid keeps the tick count (it just fits with room to spare)")

        // A coarser subdivision SHRINKS ticksPerBar and re-clamps.
        vm.setSubdivision(.quarter)             // ticksPerBar 4 → max 3
        XCTAssertEqual(vm.maxPickupTicks, 3)
        XCTAssertLessThanOrEqual(vm.pickupTicks, 3)
    }

    /// The UI note-value label maps ticks onto friendly beat fractions per the current grid.
    func testPickupNoteValueLabels() {
        let vm = MetronomeViewModel()
        vm.setSubdivision(.eighth)              // 2 ticks/beat
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 1), "½ beat")
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 2), "1 beat")
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 3), "1½ beats")
        vm.setSubdivision(.quarter)            // 1 tick/beat
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 1), "1 beat")
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 2), "2 beats")
        XCTAssertEqual(vm.pickupNoteValueLabel(ticks: 0), "Off")
    }
}
