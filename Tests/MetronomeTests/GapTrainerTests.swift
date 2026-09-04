import XCTest
@testable import Metronome

/// Pure, deterministic tests for the gap-click trainer's muting policy (feature 1). No audio engine —
/// these pin the decision the render path applies, exactly as `ClickMathTests` pins the timing math.
/// The audio-level proof that the trainer rides the sample-accurate grid lives in
/// `TrainerRenderAccuracyTests`.
final class GapTrainerTests: XCTestCase {

    // MARK: Helpers

    /// Beats in `0..<count` (at `beatsPerBar`) whose on-beat gate is `.silence`.
    private func silencedBeats(_ t: GapTrainer, count: Int, beatsPerBar: Int = 4) -> [Int] {
        (0..<count).filter { t.gate(globalBeat: $0, beatsPerBar: beatsPerBar, posInBeat: 0) == .silence }
    }

    private func silencedFraction(_ t: GapTrainer, count: Int, beatsPerBar: Int = 4) -> Double {
        Double(silencedBeats(t, count: count, beatsPerBar: beatsPerBar).count) / Double(count)
    }

    // MARK: - Random mode: correct % muted over a window (seeded)

    func testRandomMutesApproximatelyTheSetPercentageOverAWindow() {
        // keepDownbeat off so the percentage applies uniformly to every beat.
        for percent in [10, 25, 40, 60] {
            var t = GapTrainer()
            t.isEnabled = true
            t.mode = .random
            t.keepDownbeat = false
            t.mutePercent = percent
            t.seed = 0xABCD_1234_5678_9F01

            let n = 4000
            let fraction = silencedFraction(t, count: n)
            XCTAssertEqual(fraction, Double(percent) / 100.0, accuracy: 0.03,
                "random muting at \(percent)% should hit ~\(percent)% over \(n) beats, got \(fraction * 100)%")
        }
    }

    func testRandomZeroAndHundredPercentAreTotal() {
        var t = GapTrainer(); t.isEnabled = true; t.mode = .random; t.keepDownbeat = false
        t.mutePercent = 0
        XCTAssertTrue(silencedBeats(t, count: 500).isEmpty, "0% must mute nothing")
        t.mutePercent = 100
        XCTAssertEqual(silencedBeats(t, count: 500).count, 500, "100% must mute every beat")
    }

    func testRandomIsDeterministicForASeedAndVariesBySeed() {
        var a = GapTrainer(); a.isEnabled = true; a.mode = .random; a.keepDownbeat = false
        a.mutePercent = 30; a.seed = 111
        var b = a; b.seed = 111            // same seed
        var c = a; c.seed = 999            // different seed

        XCTAssertEqual(silencedBeats(a, count: 1000), silencedBeats(b, count: 1000),
                       "same seed must reproduce the exact pattern")
        XCTAssertNotEqual(silencedBeats(a, count: 1000), silencedBeats(c, count: 1000),
                          "a different seed must give a different pattern")
    }

    func testRandomKeepsDownbeatAudibleWhenRequested() {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .random; t.keepDownbeat = true
        t.mutePercent = 100                 // every beat would be silenced…
        let beatsPerBar = 4
        for globalBeat in 0..<64 {
            let onBeat = t.gate(globalBeat: globalBeat, beatsPerBar: beatsPerBar, posInBeat: 0)
            if globalBeat % beatsPerBar == 0 {
                XCTAssertEqual(onBeat, .softDownbeat, "downbeat must stay audible (soft) when kept")
                // …but the downbeat's subdivisions stay silent (only the on-beat tick sounds softly).
                XCTAssertEqual(t.gate(globalBeat: globalBeat, beatsPerBar: beatsPerBar, posInBeat: 1), .silence)
            } else {
                XCTAssertEqual(onBeat, .silence, "non-downbeats are silenced at 100%")
            }
        }

        // At a partial percentage, downbeats are never fully silent (either played or kept soft).
        t.mutePercent = 50
        for bar in 0..<200 {
            let gate = t.gate(globalBeat: bar * beatsPerBar, beatsPerBar: beatsPerBar, posInBeat: 0)
            XCTAssertNotEqual(gate, .silence, "the downbeat of bar \(bar) must never be silenced when kept")
        }
    }

    // MARK: - Bars on/off pattern

    func testBarsOnOffPattern() {
        func assertPattern(on: Int, off: Int, beatsPerBar: Int, expectedOffBars: Set<Int>, upToBar: Int) {
            var t = GapTrainer()
            t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = false
            t.barsOn = on; t.barsOff = off
            for bar in 0..<upToBar {
                let shouldBeOff = expectedOffBars.contains(bar)
                for beatInBar in 0..<beatsPerBar {
                    let globalBeat = bar * beatsPerBar + beatInBar
                    let gate = t.gate(globalBeat: globalBeat, beatsPerBar: beatsPerBar, posInBeat: 0)
                    if shouldBeOff {
                        XCTAssertEqual(gate, .silence, "bar \(bar) beat \(beatInBar) should be silent (\(on) on/\(off) off)")
                    } else {
                        XCTAssertEqual(gate, .play, "bar \(bar) beat \(beatInBar) should play (\(on) on/\(off) off)")
                    }
                }
            }
        }
        // 2 on / 2 off → off bars 2,3, 6,7, 10,11…
        assertPattern(on: 2, off: 2, beatsPerBar: 3, expectedOffBars: [2, 3, 6, 7, 10, 11], upToBar: 12)
        // 1 on / 3 off → off bars 1,2,3, 5,6,7…
        assertPattern(on: 1, off: 3, beatsPerBar: 4, expectedOffBars: [1, 2, 3, 5, 6, 7, 9, 10, 11], upToBar: 12)
        // 3 on / 1 off → off bars 3, 7, 11…
        assertPattern(on: 3, off: 1, beatsPerBar: 4, expectedOffBars: [3, 7, 11], upToBar: 12)
    }

    func testBarsModeKeepsSoftDownbeatInOffBars() {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = true
        t.barsOn = 1; t.barsOff = 1
        let beatsPerBar = 4
        // Bar 0 on (all play); bar 1 off (soft downbeat, rest silent); bar 2 on; bar 3 off…
        for bar in 0..<8 {
            let off = bar % 2 == 1
            for beatInBar in 0..<beatsPerBar {
                let gb = bar * beatsPerBar + beatInBar
                let gate = t.gate(globalBeat: gb, beatsPerBar: beatsPerBar, posInBeat: 0)
                if !off {
                    XCTAssertEqual(gate, .play, "on-bar \(bar) must play")
                } else if beatInBar == 0 {
                    XCTAssertEqual(gate, .softDownbeat, "off-bar \(bar) downbeat must be soft")
                } else {
                    XCTAssertEqual(gate, .silence, "off-bar \(bar) beat \(beatInBar) must be silent")
                }
            }
        }
    }

    // MARK: - Ramp progression

    func testRampRaisesRandomMuteFractionOverTime() {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .random; t.keepDownbeat = false
        t.mutePercent = 20; t.rampEnabled = true; t.rampMutePercentPeak = 80; t.rampBars = 10

        XCTAssertEqual(t.effectiveMuteFraction(barIndex: 0), 0.20, accuracy: 1e-9, "starts at the base %")
        XCTAssertEqual(t.effectiveMuteFraction(barIndex: 5), 0.50, accuracy: 1e-9, "halfway up the ramp")
        XCTAssertEqual(t.effectiveMuteFraction(barIndex: 10), 0.80, accuracy: 1e-9, "reaches the peak")
        XCTAssertEqual(t.effectiveMuteFraction(barIndex: 40), 0.80, accuracy: 1e-9, "holds at the peak after")

        // Non-decreasing across the whole ramp.
        for bar in 0..<40 {
            XCTAssertLessThanOrEqual(t.effectiveMuteFraction(barIndex: bar),
                                     t.effectiveMuteFraction(barIndex: bar + 1) + 1e-12,
                                     "ramp must never decrease (bar \(bar))")
        }

        // And it actually mutes more later than earlier (measured over equal seeded windows).
        func silenceFraction(bars: Range<Int>) -> Double {
            let beats = (bars.lowerBound * 4..<bars.upperBound * 4)
            let muted = beats.filter { t.gate(globalBeat: $0, beatsPerBar: 4, posInBeat: 0) == .silence }.count
            return Double(muted) / Double(beats.count)
        }
        let early = silenceFraction(bars: 0..<5)     // ~20–44% muted
        let late = silenceFraction(bars: 30..<35)    // held at the 80% peak
        XCTAssertLessThan(early, late, "later bars must be muted more than earlier ones under the ramp")
    }

    func testRampGrowsBarsOffOverTime() {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = false
        t.barsOn = 2; t.barsOff = 1; t.rampEnabled = true; t.rampBarsOffPeak = 4

        // Off-phase lengths should grow 1,2,3,4 then hold at 4. Extract consecutive off-runs.
        var runs: [Int] = []
        var current = 0
        for bar in 0..<48 {
            if t.barsModeSilenced(barIndex: bar) {
                current += 1
            } else if current > 0 {
                runs.append(current); current = 0
            }
        }
        if current > 0 { runs.append(current) }

        XCTAssertGreaterThanOrEqual(runs.count, 4, "expected several off-phases, got \(runs)")
        XCTAssertEqual(Array(runs.prefix(4)), [1, 2, 3, 4], "off-phase must grow 1→2→3→4, got \(runs)")
        XCTAssertTrue(runs.dropFirst(4).allSatisfy { $0 == 4 }, "off-phase must hold at the peak (4), got \(runs)")
    }

    // MARK: - Disabled + Codable

    func testDisabledTrainerAlwaysPlays() {
        var t = GapTrainer()   // isEnabled defaults false
        t.mode = .random; t.mutePercent = 100; t.barsOff = 8
        for gb in 0..<200 {
            XCTAssertEqual(t.gate(globalBeat: gb, beatsPerBar: 4, posInBeat: 0), .play,
                           "a disabled trainer must never silence anything")
        }
    }

    func testCodableRoundTrip() throws {
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.mutePercent = 33; t.barsOn = 3; t.barsOff = 5
        t.keepDownbeat = false; t.seed = 0xDEAD_BEEF_CAFE_1234
        t.rampEnabled = true; t.rampBars = 12; t.rampMutePercentPeak = 70; t.rampBarsOffPeak = 6

        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(GapTrainer.self, from: data)
        XCTAssertEqual(t, decoded, "GapTrainer must round-trip through Codable unchanged")
    }

    func testNormalizedClampsToSaneRanges() {
        var t = GapTrainer()
        t.mutePercent = 250; t.barsOn = 0; t.barsOff = 99; t.rampBars = 0; t.rampMutePercentPeak = -5; t.rampBarsOffPeak = 0
        let n = t.normalized()
        XCTAssertEqual(n.mutePercent, 100)
        XCTAssertEqual(n.barsOn, 1)
        XCTAssertEqual(n.barsOff, 16)
        XCTAssertEqual(n.rampBars, 1)
        XCTAssertEqual(n.rampMutePercentPeak, 0)
        XCTAssertEqual(n.rampBarsOffPeak, 1)
    }

    // MARK: - RenderPlan integration (tick → beat/bar mapping)

    func testRenderPlanTrainerGateMapsTicksToBeats() {
        // 1 bar on / 1 bar off, 4/4 quarter (ticksPerBeat 1, beatsPerBar 4), downbeat not kept.
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = false; t.barsOn = 1; t.barsOff = 1
        let plan = RenderPlan(config: MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter),
                              sampleRate: 44_100, trainer: t)
        // Ticks 0..3 = bar 0 (on); 4..7 = bar 1 (off); 8..11 = bar 2 (on)…
        for tick in 0..<16 {
            let bar = tick / 4
            let expected: GapTrainer.Gate = (bar % 2 == 1) ? .silence : .play
            XCTAssertEqual(plan.trainerGate(forTick: tick), expected, "tick \(tick) (bar \(bar))")
        }
    }

    func testRenderPlanTrainerGateSoftDownbeatWithSubdivision() {
        // 1 on / 1 off, keep downbeat, 4/4 eighth (ticksPerBeat 2, beatsPerBar 4): off bar = bar 1 =
        // global beats 4..7 = ticks 8..15. The downbeat tick (8) is soft; its off-beat eighth (9) silent.
        var t = GapTrainer()
        t.isEnabled = true; t.mode = .barsOnOff; t.keepDownbeat = true; t.barsOn = 1; t.barsOff = 1
        let plan = RenderPlan(config: MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth),
                              sampleRate: 44_100, trainer: t)
        XCTAssertEqual(plan.trainerGate(forTick: 0), .play)          // bar 0, on
        XCTAssertEqual(plan.trainerGate(forTick: 8), .softDownbeat)  // bar 1 downbeat, kept soft
        XCTAssertEqual(plan.trainerGate(forTick: 9), .silence)       // bar 1 downbeat's off-eighth, silent
        XCTAssertEqual(plan.trainerGate(forTick: 10), .silence)      // bar 1 beat 2, silent
        XCTAssertEqual(plan.trainerGate(forTick: 16), .play)         // bar 2, on again
    }

    func testRenderPlanTrainerDisabledByDefaultLeavesGatePlaying() {
        let plan = RenderPlan(config: MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth),
                              sampleRate: 44_100)   // default trainer = disabled
        for tick in 0..<64 {
            XCTAssertEqual(plan.trainerGate(forTick: tick), .play)
        }
    }
}
