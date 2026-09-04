import XCTest
@testable import Metronome

/// Pure, deterministic tests for the timing/accent math. No audio engine involved — these pin down
/// the model that the audio render path (and the offline accuracy test) rely on.
final class ClickMathTests: XCTestCase {

    func testSubdivisionTickCounts() {
        XCTAssertEqual(Subdivision.quarter.ticksPerBeat, 1)
        XCTAssertEqual(Subdivision.eighth.ticksPerBeat, 2)
        XCTAssertEqual(Subdivision.triplet.ticksPerBeat, 3)
        XCTAssertEqual(Subdivision.sixteenth.ticksPerBeat, 4)
        XCTAssertEqual(Subdivision.thirtysecond.ticksPerBeat, 8)   // 32nd = 8 clicks per beat
    }

    func testTimeSignatureClamping() {
        XCTAssertEqual(TimeSignature(numerator: 0, denominator: 4).numerator, 1)
        XCTAssertEqual(TimeSignature(numerator: 99, denominator: 4).numerator, 32)  // widened cap (was 16)
        XCTAssertEqual(TimeSignature(numerator: 32, denominator: 4).numerator, 32)  // max arbitrary numerator
        XCTAssertEqual(TimeSignature(numerator: 11, denominator: 8).numerator, 11)  // odd meter preserved
        XCTAssertEqual(TimeSignature(numerator: 3, denominator: 3).denominator, 4)  // invalid → 4
        XCTAssertEqual(TimeSignature(numerator: 6, denominator: 8).denominator, 8)
    }

    func testTempoClamping() {
        XCTAssertEqual(MetronomeConfiguration(bpm: 5).bpm, 30)
        XCTAssertEqual(MetronomeConfiguration(bpm: 9000).bpm, 300)
    }

    func testAccentNormalizationDefaultsDownbeat() {
        let c = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(c.accents, [true, false, false, false])
    }

    func testAccentNormalizationResizes() {
        XCTAssertEqual(MetronomeConfiguration.normalizedAccents([true, true], count: 4),
                       [true, true, false, false])
        XCTAssertEqual(MetronomeConfiguration.normalizedAccents([true, false, true, true], count: 2),
                       [true, false])
        // All-off is forced to accent the downbeat so it is never silent-by-omission.
        XCTAssertEqual(MetronomeConfiguration.normalizedAccents([false, false, false], count: 3),
                       [true, false, false])
    }

    func testSecondsPerTick() {
        // 120 BPM, quarter → 0.5 s/beat, 1 tick/beat.
        XCTAssertEqual(MetronomeConfiguration(bpm: 120, subdivision: .quarter).secondsPerTick,
                       0.5, accuracy: 1e-12)
        // 120 BPM, sixteenth → 0.5 / 4 = 0.125 s/tick.
        XCTAssertEqual(MetronomeConfiguration(bpm: 120, subdivision: .sixteenth).secondsPerTick,
                       0.125, accuracy: 1e-12)
    }

    func testTicksPerBar() {
        let c = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 7, denominator: 8),
                                       subdivision: .eighth)
        XCTAssertEqual(c.ticksPerBar, 14)
    }

    func testFrameMappingIsExactForCleanDivisors() {
        let sr = 48_000.0
        let config = MetronomeConfiguration(bpm: 120, subdivision: .quarter)   // 24_000 frames/tick
        XCTAssertEqual(config.frame(forTick: 0, sampleRate: sr), 0)
        XCTAssertEqual(config.frame(forTick: 1, sampleRate: sr), 24_000)
        XCTAssertEqual(config.frame(forTick: 10, sampleRate: sr), 240_000)
        XCTAssertEqual(config.frame(forTick: 1000, sampleRate: sr), 24_000_000)
    }

    /// The closed-form mapping's deviation from ideal continuous time is bounded by ½ sample for
    /// *every* tick and — crucially — never accumulates: the 5000th tick is as tight as the first.
    func testFrameMappingZeroDriftAcrossTempos() {
        let sr = 44_100.0
        let tempos: [Double] = [30, 40, 73, 120, 144, 199, 250, 300]
        let subs: [Subdivision] = [.quarter, .eighth, .triplet, .sixteenth]
        for bpm in tempos {
            for sub in subs {
                let config = MetronomeConfiguration(bpm: bpm, subdivision: sub)
                let spt = config.secondsPerTick
                var maxDeviation = 0.0
                for n in 0...5000 {
                    let placed = Double(config.frame(forTick: n, sampleRate: sr))
                    let ideal = Double(n) * spt * sr
                    maxDeviation = max(maxDeviation, abs(placed - ideal))
                }
                XCTAssertLessThanOrEqual(maxDeviation, 0.5,
                    "drift exceeded ½ sample at \(bpm) BPM \(sub.displayName)")
            }
        }
    }

    func testRenderPlanMatchesConfiguration() {
        let sr = 48_000.0
        let config = MetronomeConfiguration(
            bpm: 137,
            timeSignature: TimeSignature(numerator: 5, denominator: 8),
            subdivision: .triplet,
            accents: [true, false, true, false, false]
        )
        let plan = RenderPlan(config: config, sampleRate: sr)
        for n in 0...2000 {
            XCTAssertEqual(plan.frame(forTick: n), config.frame(forTick: n, sampleRate: sr))
            XCTAssertEqual(plan.accentLevel(forTick: n), config.accentLevel(forTick: n))
            XCTAssertEqual(plan.beatIndex(forTick: n), config.beatIndex(forTick: n))
        }
    }

    func testAccentLevelsQuarter() {
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)   // beat 1 (accented downbeat)
        XCTAssertEqual(c.accentLevel(forTick: 1), .normal)   // beat 2
        XCTAssertEqual(c.accentLevel(forTick: 2), .normal)   // beat 3
        XCTAssertEqual(c.accentLevel(forTick: 4), .strong)   // next bar downbeat
    }

    func testAccentLevelsWithSubdivision() {
        let e = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth)
        XCTAssertEqual(e.accentLevel(forTick: 0), .strong)   // beat 1
        XCTAssertEqual(e.accentLevel(forTick: 1), .weak)     // off-beat "and"
        XCTAssertEqual(e.accentLevel(forTick: 2), .normal)   // beat 2
        XCTAssertNil(e.beatIndex(forTick: 1))
        XCTAssertEqual(e.beatIndex(forTick: 2), 1)
    }

    func testCustomAccentPattern() {
        // Accent beats 1 and 3 in 4/4.
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quarter,
                                       accents: [true, false, true, false])
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)
        XCTAssertEqual(c.accentLevel(forTick: 1), .normal)
        XCTAssertEqual(c.accentLevel(forTick: 2), .strong)
        XCTAssertEqual(c.accentLevel(forTick: 3), .normal)
    }

    // MARK: - Compound meter grouping (6/8, 9/8, 12/8)

    func testCompoundMeterDetection() {
        XCTAssertTrue(TimeSignature(numerator: 6, denominator: 8).isCompound)
        XCTAssertTrue(TimeSignature(numerator: 9, denominator: 8).isCompound)
        XCTAssertTrue(TimeSignature(numerator: 12, denominator: 8).isCompound)
        // Not compound: single-group 3/8, any /4 meter, and non-triple /8 numerators.
        XCTAssertFalse(TimeSignature(numerator: 3, denominator: 8).isCompound)
        XCTAssertFalse(TimeSignature(numerator: 6, denominator: 4).isCompound)
        XCTAssertFalse(TimeSignature(numerator: 4, denominator: 8).isCompound)
        XCTAssertFalse(TimeSignature(numerator: 7, denominator: 8).isCompound)
        XCTAssertEqual(TimeSignature(numerator: 12, denominator: 8).compoundGroupCount, 4)
    }

    func testCompoundMetersDefaultToGroupHeadAccents() {
        // Group heads (beats 1, 4, 7, 10) accented by default for compound meters.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 8)).accents,
                       [true, false, false, true, false, false])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 9, denominator: 8)).accents,
                       [true, false, false, true, false, false, true, false, false])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 12, denominator: 8)).accents,
                       [true, false, false, true, false, false, true, false, false, true, false, false])
        // Simple meters unchanged: only the downbeat. 6/4 is duple-simple, NOT compound.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: .common).accents, [true, false, false, false])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 4)).accents,
                       [true, false, false, false, false, false])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 3, denominator: 8)).accents,
                       [true, false, false])
    }

    func testCompoundAccentLevelsMarkGroupHeads() {
        // 6/8 at the base pulse: strong on beats 1 & 4 (group heads), normal on the inner pulses.
        let c = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                       subdivision: .quarter)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)   // group 1 head
        XCTAssertEqual(c.accentLevel(forTick: 1), .normal)
        XCTAssertEqual(c.accentLevel(forTick: 2), .normal)
        XCTAssertEqual(c.accentLevel(forTick: 3), .strong)   // group 2 head
        XCTAssertEqual(c.accentLevel(forTick: 4), .normal)
        XCTAssertEqual(c.accentLevel(forTick: 5), .normal)
        XCTAssertEqual(c.accentLevel(forTick: 6), .strong)   // next bar, group 1 head
    }

    // MARK: - Voice counting map (which spoken token lands on which tick — pure, no audio)

    private func plan(_ bpm: Double = 120, _ ts: TimeSignature = .common, _ sub: Subdivision) -> RenderPlan {
        RenderPlan(config: MetronomeConfiguration(bpm: bpm, timeSignature: ts, subdivision: sub),
                   sampleRate: 48_000)
    }

    func testVoiceTokenQuarterSpeaksOnlyNumbers() {
        let p = plan(120, .common, .quarter)
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))   // "one"
        XCTAssertEqual(p.voiceToken(forTick: 1), .number(1))   // "two"
        XCTAssertEqual(p.voiceToken(forTick: 4), .number(0))   // next bar → "one"
    }

    func testVoiceTokenEighthCountsAnd() {
        let p = plan(120, .common, .eighth)   // "1 and 2 and …"
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))
        XCTAssertEqual(p.voiceToken(forTick: 1), .syllable(.and))
        XCTAssertEqual(p.voiceToken(forTick: 2), .number(1))
        XCTAssertEqual(p.voiceToken(forTick: 3), .syllable(.and))
    }

    func testVoiceTokenSixteenthCountsEAndA() {
        let p = plan(120, .common, .sixteenth)   // "1 e and a 2 e and a …"
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))
        XCTAssertEqual(p.voiceToken(forTick: 1), .syllable(.e))
        XCTAssertEqual(p.voiceToken(forTick: 2), .syllable(.and))
        XCTAssertEqual(p.voiceToken(forTick: 3), .syllable(.a))
        XCTAssertEqual(p.voiceToken(forTick: 4), .number(1))
        XCTAssertEqual(p.voiceToken(forTick: 5), .syllable(.e))
    }

    func testVoiceTokenTripletCountsTripLet() {
        let p = plan(120, .common, .triplet)   // "1 trip let 2 trip let …"
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))
        XCTAssertEqual(p.voiceToken(forTick: 1), .syllable(.trip))
        XCTAssertEqual(p.voiceToken(forTick: 2), .syllable(.letSub))
        XCTAssertEqual(p.voiceToken(forTick: 3), .number(1))
    }

    func testVoiceTokenThirtySecondClicksBetweenBeats() {
        // No concise standard syllables for 32nds: speak the beat number, click the in-between ticks.
        let p = plan(120, .common, .thirtysecond)
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))
        for t in 1..<8 { XCTAssertEqual(p.voiceToken(forTick: t), VoiceToken.none) }
        XCTAssertEqual(p.voiceToken(forTick: 8), .number(1))
    }

    func testVoiceTokenCompoundCountsInGroups() {
        // 6/8 felt in 2: "1 trip let 2 trip let" — group heads speak the group ordinal, inner pulses the
        // triplet syllables, so the count reflects the dotted-quarter grouping.
        let p = plan(120, TimeSignature(numerator: 6, denominator: 8), .quarter)
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))          // "one"  (group 1 head)
        XCTAssertEqual(p.voiceToken(forTick: 1), .syllable(.trip))
        XCTAssertEqual(p.voiceToken(forTick: 2), .syllable(.letSub))
        XCTAssertEqual(p.voiceToken(forTick: 3), .number(1))          // "two"  (group 2 head)
        XCTAssertEqual(p.voiceToken(forTick: 4), .syllable(.trip))
        XCTAssertEqual(p.voiceToken(forTick: 5), .syllable(.letSub))
        XCTAssertEqual(p.voiceToken(forTick: 6), .number(0))          // next bar → "one"

        // 12/8 → four groups counted "1 … 2 … 3 … 4 …".
        let q = plan(120, TimeSignature(numerator: 12, denominator: 8), .quarter)
        XCTAssertEqual(q.voiceToken(forTick: 9), .number(3))          // "four" (group 4 head)
    }
}
