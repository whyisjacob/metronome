import XCTest
@testable import Metronome

/// Pure, deterministic tests for the pickup / count-in **theory** — no audio engine. The expected counts
/// are written out by hand from the musical spec (a `k`-beat pickup in an `N`-beat bar counts beats
/// `N−k+1 … N`, then the strong downbeat "1"), never derived from the code under test, so a wrong shift
/// would fail here. The sample-accurate placement of those beats is proven separately, on real rendered
/// audio, in `PickupRenderAccuracyTests`.
///
/// `@MainActor` because one case drives `MetronomeViewModel` (a `@MainActor` type); the pure `RenderPlan`
/// cases are unaffected by running on the main actor.
@MainActor
final class PickupTests: XCTestCase {

    private let sr = 48_000.0

    private func plan(_ ts: TimeSignature, _ sub: Subdivision, pickup: Pickup, bpm: Double = 120) -> RenderPlan {
        RenderPlan(config: MetronomeConfiguration(bpm: bpm, timeSignature: ts, subdivision: sub),
                   sampleRate: sr, pickup: pickup)
    }

    /// One meter/pickup case. `counts` is the 1-based sequence of numbers the pickup must speak/show, taken
    /// straight from the spec table. All use the main-beat (quarter) subdivision, so ticks-per-beat is 1
    /// (a musical fact, hard-coded), i.e. global beat `j` is tick `j`.
    private struct C { let n: Int; let d: Int; let k: Int; let counts: [Int] }

    /// (c) The spoken/counted numbers are the TAIL of the bar, per the spec, for every required meter; and
    /// (b) each pickup beat is the unaccented `.pickup` lead-in while the first real downbeat is `.strong`.
    func testPickupCountsAreTailOfBarThenStrongDownbeat() {
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
            let p = plan(ts, .quarter, pickup: Pickup(beats: c.k))
            let label = "\(c.n)/\(c.d) k=\(c.k)"

            for (j, count) in c.counts.enumerated() {
                let tick = j                               // tpb == 1 for the main-beat subdivision
                XCTAssertTrue(p.isPickup(forTick: tick), "\(label): beat \(j) should be a pickup beat")
                XCTAssertEqual(p.voiceToken(forTick: tick), .number(count - 1),
                               "\(label): pickup beat \(j) should count \(count)")
                XCTAssertEqual(p.beatIndex(forTick: tick), count - 1,
                               "\(label): pickup beat \(j) visual index")
                XCTAssertEqual(p.accentLevel(forTick: tick), .pickup,
                               "\(label): a pickup beat must be the unaccented lead-in, never the strong accent")
            }

            // The first real beat after the pickup is the STRONG downbeat "1".
            let downTick = c.k
            XCTAssertFalse(p.isPickup(forTick: downTick), "\(label): the downbeat is not a pickup beat")
            XCTAssertEqual(p.voiceToken(forTick: downTick), .number(0), "\(label): the downbeat counts 1")
            XCTAssertEqual(p.beatIndex(forTick: downTick), 0, "\(label): the downbeat is beat 1")
            XCTAssertEqual(p.accentLevel(forTick: downTick), .strong,
                           "\(label): the first beat after the pickup must carry the STRONG accent")
        }
    }

    /// The pickup beats sit on the exact tail global-beat indices (a 3-beat pickup in 4/4 occupies global
    /// beats 0,1,2 → counts 2,3,4), and the downbeat is at global beat k. This is the tick→count map the
    /// engine schedules from.
    func testPickupBeatsOccupyTheLeadInGlobalBeats() {
        let p = plan(.common, .quarter, pickup: Pickup(beats: 3))   // 4/4, counts 2,3,4
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(1))        // "two"
        XCTAssertEqual(p.voiceToken(forTick: 1), .number(2))        // "three"
        XCTAssertEqual(p.voiceToken(forTick: 2), .number(3))        // "four"
        XCTAssertEqual(p.voiceToken(forTick: 3), .number(0))        // downbeat "one"
    }

    /// (d) By default the pickup plays ONCE: only the lead-in global beats are pickups; every beat after
    /// the first downbeat is a normal loop beat, and the downbeats recur every N beats from `g = k`.
    func testPickupPlaysOnceByDefault() {
        let k = 2
        let p = plan(.common, .quarter, pickup: Pickup(beats: k))   // 4/4
        XCTAssertTrue(p.isPickup(forTick: 0))
        XCTAssertTrue(p.isPickup(forTick: 1))
        // No further pickup beats for several bars — the lead-in is one-time.
        for g in k..<(k + 4 * 4) {
            XCTAssertFalse(p.isPickup(forTick: g), "beat \(g) must NOT be a pickup — the lead-in plays once")
        }
        // The bar downbeats recur at g = k, k+4, k+8, … each strong and counted "1".
        for g in stride(from: k, through: k + 3 * 4, by: 4) {
            XCTAssertEqual(p.accentLevel(forTick: g), .strong, "downbeat at g=\(g) must be strong")
            XCTAssertEqual(p.beatIndex(forTick: g), 0, "downbeat at g=\(g) is beat 1")
        }
    }

    /// The (optional, non-default) repeat mode re-inserts the pickup before every bar: the lead-in beat
    /// recurs at the start of each `k + N` cycle, with the downbeat right after it.
    func testPickupRepeatsEachCycleWhenEnabled() {
        let p = plan(.common, .quarter, pickup: Pickup(beats: 1, repeatsEachCycle: true))  // 4/4, period 5
        for g in [0, 5, 10] {
            XCTAssertTrue(p.isPickup(forTick: g), "repeat: g=\(g) should be a pickup beat")
            XCTAssertEqual(p.voiceToken(forTick: g), .number(3), "repeat: 4/4 pickup counts 4")
            XCTAssertEqual(p.accentLevel(forTick: g), .pickup)
        }
        for g in [1, 6, 11] {
            XCTAssertFalse(p.isPickup(forTick: g), "repeat: g=\(g) should be a real downbeat")
            XCTAssertEqual(p.accentLevel(forTick: g), .strong)
            XCTAssertEqual(p.beatIndex(forTick: g), 0)
        }
    }

    /// A pickup counts its beats; its in-between subdivisions click (never speak a syllable) so the lead-in
    /// stays crisp. Here a 1-beat pickup in 4/4 with an eighth subdivision: the beat speaks "4", the "and"
    /// is a (clicked) `.none`; then the downbeat speaks "1" and its "and" is the normal syllable again.
    func testPickupSubdivisionsClickNotSpoken() {
        let p = plan(.common, .eighth, pickup: Pickup(beats: 1))   // tpb = 2
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(3))       // pickup beat → "four"
        XCTAssertEqual(p.voiceToken(forTick: 1), VoiceToken.none)  // pickup "and" → clicked, not spoken
        XCTAssertEqual(p.voiceToken(forTick: 2), .number(0))       // downbeat → "one"
        XCTAssertEqual(p.voiceToken(forTick: 3), .syllable(.and))  // normal "and" resumes after the pickup
    }

    /// With no pickup, `RenderPlan` is byte-for-byte its old self — the labeling helpers match the pure
    /// config exactly (this is what keeps every existing accuracy/equality test valid).
    func testNoPickupMatchesPlainConfig() {
        let config = MetronomeConfiguration(bpm: 137, timeSignature: TimeSignature(numerator: 5, denominator: 8),
                                            subdivision: .triplet)
        let plain = RenderPlan(config: config, sampleRate: sr)                 // pickup defaults to .none
        for n in 0...600 {
            XCTAssertEqual(plain.accentLevel(forTick: n), config.accentLevel(forTick: n), "accent \(n)")
            XCTAssertEqual(plain.beatIndex(forTick: n), config.beatIndex(forTick: n), "beat \(n)")
            XCTAssertFalse(plain.isPickup(forTick: n), "no pickup → no pickup beats")
        }
    }

    // MARK: - Pickup value type (once vs repeat labeling)

    func testPickupHelperTailCountFormula() {
        // 4/4, 2-beat pickup: global beats 0,1 → bar beats 2,3 (0-based) → counts "3","4"; then downbeat 0.
        let p = Pickup(beats: 2)
        XCTAssertTrue(p.isPickupBeat(globalBeat: 0, beatsPerBar: 4))
        XCTAssertTrue(p.isPickupBeat(globalBeat: 1, beatsPerBar: 4))
        XCTAssertFalse(p.isPickupBeat(globalBeat: 2, beatsPerBar: 4))
        XCTAssertEqual(p.beatInBar(globalBeat: 0, beatsPerBar: 4), 2)
        XCTAssertEqual(p.beatInBar(globalBeat: 1, beatsPerBar: 4), 3)
        XCTAssertEqual(p.beatInBar(globalBeat: 2, beatsPerBar: 4), 0)
    }

    func testPickupEffectiveBeatsClampsToIncompleteBar() {
        // A pickup can never be a whole bar or more: 4 beats in 4/4 clamps to 3; anything in 1/4 → 0.
        XCTAssertEqual(Pickup(beats: 4).effectiveBeats(beatsPerBar: 4), 3)
        XCTAssertEqual(Pickup(beats: 9).effectiveBeats(beatsPerBar: 4), 3)
        XCTAssertEqual(Pickup(beats: 1).effectiveBeats(beatsPerBar: 1), 0)
        XCTAssertEqual(Pickup(beats: 0).effectiveBeats(beatsPerBar: 4), 0)
    }

    // MARK: - (e) Clamping to the meter (view model)

    func testPickupClampsToMeterAndReclampsOnMeterChange() {
        let vm = MetronomeViewModel()          // default 4/4 → max pickup 3
        vm.setPickupBeats(3)
        XCTAssertEqual(vm.pickupBeats, 3)
        vm.setPickupBeats(9)                    // clamps to the meter max
        XCTAssertEqual(vm.pickupBeats, 3)

        vm.setNumerator(2)                      // 2/4 → max pickup 1
        XCTAssertEqual(vm.maxPickupBeats, 1)
        XCTAssertEqual(vm.pickupBeats, 1, "the count-in must re-clamp when the bar gets shorter")

        vm.setNumerator(3)                      // 3/4 → max 2, but a shrunk value does not re-expand
        XCTAssertEqual(vm.maxPickupBeats, 2)
        XCTAssertEqual(vm.pickupBeats, 1)

        // Switching to a compound meter (6/8 → felt in 2) also re-clamps to its 2 main beats.
        vm.setNumerator(6)
        vm.setDenominator(8)
        XCTAssertEqual(vm.beatsPerBar, 2, "6/8 is felt in 2 dotted-quarter beats")
        XCTAssertEqual(vm.maxPickupBeats, 1)
        XCTAssertLessThanOrEqual(vm.pickupBeats, 1)
    }
}
