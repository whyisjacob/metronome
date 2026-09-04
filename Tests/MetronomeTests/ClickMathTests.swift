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
        // 4/4 defaults to a strong downbeat and a secondary (medium) accent on beat 3 — the familiar 2+2
        // grouping — with the other beats normal.
        let c = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 4, denominator: 4))
        XCTAssertEqual(c.accents, [.strong, .normal, .medium, .normal])
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
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)   // beat 1 (strong downbeat)
        XCTAssertEqual(c.accentLevel(forTick: 1), .normal)   // beat 2
        XCTAssertEqual(c.accentLevel(forTick: 2), .medium)   // beat 3 (secondary accent by default)
        XCTAssertEqual(c.accentLevel(forTick: 3), .normal)   // beat 4
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
        // Compound meters are felt in dotted-quarter beats: beat 1 strong, every later group head medium.
        // The accent array is one entry per MAIN beat (2 for 6/8, 3 for 9/8, 4 for 12/8).
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 8)).accents,
                       [.strong, .medium])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 9, denominator: 8)).accents,
                       [.strong, .medium, .medium])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 12, denominator: 8)).accents,
                       [.strong, .medium, .medium, .medium])
        // Simple meters: 4/4 keeps its 2+2 (strong, _, medium, _); 6/4 is duple-simple (downbeat only);
        // 3/8 is a single group (downbeat only), NOT compound.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: .common).accents,
                       [.strong, .normal, .medium, .normal])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 4)).accents,
                       [.strong, .normal, .normal, .normal, .normal, .normal])
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 3, denominator: 8)).accents,
                       [.strong, .normal, .normal])
    }

    func testCompoundAccentLevelsMarkGroupHeads() {
        // 6/8 felt in 2 (main-beat / quarter subdivision): two dotted-quarter beats, strong then medium.
        let c = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                       subdivision: .quarter)
        XCTAssertEqual(c.ticksPerBeat, 1, "compound main-beat subdivision is one pulse per beat")
        XCTAssertEqual(c.beatsPerBar, 2)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)   // beat 1 (group 1 head)
        XCTAssertEqual(c.accentLevel(forTick: 1), .medium)   // beat 2 (group 2 head)
        XCTAssertEqual(c.accentLevel(forTick: 2), .strong)   // next bar, beat 1

        // With the eighth pulse each dotted-quarter beat divides in three (the "1 trip let" feel): the two
        // heads keep their strong/medium accents and the inner eighths are weak.
        let e = MetronomeConfiguration(timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                       subdivision: .eighth)
        XCTAssertEqual(e.ticksPerBeat, 3, "a compound eighth pulse is 3 per dotted-quarter beat")
        XCTAssertEqual(e.accentLevel(forTick: 0), .strong)   // beat 1
        XCTAssertEqual(e.accentLevel(forTick: 1), .weak)     // inner eighth
        XCTAssertEqual(e.accentLevel(forTick: 2), .weak)     // inner eighth
        XCTAssertEqual(e.accentLevel(forTick: 3), .medium)   // beat 2 head
        XCTAssertEqual(e.beatIndex(forTick: 3), 1)
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
        // 6/8 with the eighth pulse: each dotted-quarter beat divides in three, counted "1 trip let 2 …" —
        // the beat speaks its ordinal, the inner eighths speak the triplet syllables.
        let p = plan(120, TimeSignature(numerator: 6, denominator: 8), .eighth)
        XCTAssertEqual(p.voiceToken(forTick: 0), .number(0))          // "one"  (beat 1)
        XCTAssertEqual(p.voiceToken(forTick: 1), .syllable(.trip))
        XCTAssertEqual(p.voiceToken(forTick: 2), .syllable(.letSub))
        XCTAssertEqual(p.voiceToken(forTick: 3), .number(1))          // "two"  (beat 2)
        XCTAssertEqual(p.voiceToken(forTick: 4), .syllable(.trip))
        XCTAssertEqual(p.voiceToken(forTick: 5), .syllable(.letSub))
        XCTAssertEqual(p.voiceToken(forTick: 6), .number(0))          // next bar → "one"

        // 12/8 → four dotted-quarter beats counted "1 … 2 … 3 … 4 …".
        let q = plan(120, TimeSignature(numerator: 12, denominator: 8), .eighth)
        XCTAssertEqual(q.voiceToken(forTick: 9), .number(3))          // "four" (beat 4)
    }

    // MARK: - Asymmetric-meter default groupings (item 2)

    func testAsymmetricMeterDefaultGroupings() {
        // 5/8 → 2+3: strong on beat 1, medium (secondary) on beat 3.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 5, denominator: 8)).accents,
                       [.strong, .normal, .medium, .normal, .normal])
        // 7/8 → 2+2+3: accents on beats 1, 3, 5.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 7, denominator: 8)).accents,
                       [.strong, .normal, .medium, .normal, .medium, .normal, .normal])
        // 5/4 → 3+2: accents on beats 1, 4.
        XCTAssertEqual(MetronomeConfiguration(timeSignature: TimeSignature(numerator: 5, denominator: 4)).accents,
                       [.strong, .normal, .normal, .medium, .normal])
    }

    // MARK: - Secondary accent level (item 3)

    func testSecondaryAccentLevelIsAudiblyBetweenStrongAndNormal() {
        let c = MetronomeConfiguration(timeSignature: .common, subdivision: .quarter,
                                       accents: [.strong, .medium, .normal, .muted])
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)
        XCTAssertEqual(c.accentLevel(forTick: 1), .medium)
        XCTAssertEqual(c.accentLevel(forTick: 2), .normal)

        // The medium click's peak amplitude sits strictly between strong and normal (and above weak), so
        // it is an audibly distinct in-between loudness — proven from the generated buffer, not asserted.
        let table = ClickSoundFactory.makeClickTable(sampleRate: 44_100, sound: .classic)
        func peak(_ level: AccentLevel) -> Float { table[level.rawValue].map { abs($0) }.max() ?? 0 }
        XCTAssertGreaterThan(peak(.strong), peak(.medium))
        XCTAssertGreaterThan(peak(.medium), peak(.normal))
        XCTAssertGreaterThan(peak(.normal), peak(.weak))
        XCTAssertTrue(table[AccentLevel.muted.rawValue].isEmpty, "the muted slot is a silent (empty) buffer")
    }

    // MARK: - Per-beat mute (item 4)

    func testMutedBeatIsSilentButStillCounts() {
        // Mute beat 3 of 4/4 with an eighth subdivision: the muted beat AND its inner eighth are silent,
        // yet the beat still reports its index so the count/visual advance.
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth,
                                       accents: [.strong, .normal, .muted, .normal])
        XCTAssertEqual(c.accentLevel(forTick: 4), .muted)   // beat 3 on-beat: silent
        XCTAssertEqual(c.accentLevel(forTick: 5), .muted)   // its subdivision: also silent
        XCTAssertEqual(c.beatIndex(forTick: 4), 2)          // …but the beat still counts
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)  // other beats unaffected
        XCTAssertEqual(c.accentLevel(forTick: 6), .normal)
    }

    func testNormalizeAllowsAllMutedButPromotesAllNormalDownbeat() {
        // An all-normal pattern promotes the downbeat to strong (never accent-less by omission)…
        XCTAssertEqual(MetronomeConfiguration.normalizedAccents([.normal, .normal, .normal], count: 3),
                       [.strong, .normal, .normal])
        // …but an explicit all-muted pattern is respected (a deliberately silent bar is allowed).
        XCTAssertEqual(MetronomeConfiguration.normalizedAccents([.muted, .muted], count: 2),
                       [.muted, .muted])
    }

    func testAccentCycleOrderStrongMediumNormalMuted() {
        XCTAssertEqual(BeatAccent.strong.next, .medium)
        XCTAssertEqual(BeatAccent.medium.next, .normal)
        XCTAssertEqual(BeatAccent.normal.next, .muted)
        XCTAssertEqual(BeatAccent.muted.next, .strong)
    }

    // MARK: - Even tuplets (quintuplet / sextuplet / septuplet)

    func testTupletTickCounts() {
        XCTAssertEqual(Subdivision.quintuplet.ticksPerBeat, 5)
        XCTAssertEqual(Subdivision.sextuplet.ticksPerBeat, 6)
        XCTAssertEqual(Subdivision.septuplet.ticksPerBeat, 7)
    }

    func testTupletSecondsPerTickSplitsTheBeatEvenly() {
        // 120 BPM → 0.5 s/beat. A quintuplet is 5 equal clicks; a septuplet 7.
        XCTAssertEqual(MetronomeConfiguration(bpm: 120, subdivision: .quintuplet).secondsPerTick,
                       0.5 / 5.0, accuracy: 1e-12)
        XCTAssertEqual(MetronomeConfiguration(bpm: 120, subdivision: .septuplet).secondsPerTick,
                       0.5 / 7.0, accuracy: 1e-12)
    }

    /// Voice on a tuplet: the beat speaks its number, the in-between ticks click (no standard syllables
    /// exist for quintuplets/septuplets; the sextuplet is counted the same way here).
    func testVoiceTokenTupletsSpeakBeatNumberAndClickBetween() {
        for (sub, tpb) in [(Subdivision.quintuplet, 5), (.sextuplet, 6), (.septuplet, 7)] {
            let p = plan(120, .common, sub)
            XCTAssertEqual(p.voiceToken(forTick: 0), .number(0), "\(sub) beat 1 speaks its number")
            for t in 1..<tpb {
                XCTAssertEqual(p.voiceToken(forTick: t), VoiceToken.none,
                               "\(sub) tick \(t) should click (no spoken syllable)")
            }
            XCTAssertEqual(p.voiceToken(forTick: tpb), .number(1), "\(sub) next beat speaks its number")
        }
    }

    /// Tuplets carry the beat accent on their downbeat and are weak in between — same rule as any other
    /// subdivision, proving they drop straight into the accent model.
    func testTupletAccentLevels() {
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .quintuplet)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)     // beat 1 downbeat
        for t in 1..<5 { XCTAssertEqual(c.accentLevel(forTick: t), .weak) }
        XCTAssertEqual(c.accentLevel(forTick: 5), .normal)     // beat 2 downbeat
        XCTAssertEqual(c.beatIndex(forTick: 5), 1)
        XCTAssertNil(c.beatIndex(forTick: 3))
    }

    // MARK: - Swing / shuffle (exact frame placement — pure, no audio)

    /// Swung eighths, worked out from first principles at a sample rate where the frames are exact:
    /// 120 BPM eighth = 12 000 frames/tick straight (24 000 frames/beat). The off-beat (tick 1) moves
    /// from ½ of the beat (12 000) to ⅔ (16 000) as swing runs 0 → 1; the beats never move.
    func testSwungEighthFramesMatchFirstPrinciples() {
        let sr = 48_000.0
        // Straight (swing 0): identical to the original grid, byte-for-byte.
        let straight = MetronomeConfiguration(bpm: 120, subdivision: .eighth, swing: 0)
        XCTAssertEqual(straight.frame(forTick: 1, sampleRate: sr), 12_000)

        // Half swing: off-beat at (0.5 + 0.5/6) · 24 000 = 14 000; beats unchanged.
        let half = MetronomeConfiguration(bpm: 120, subdivision: .eighth, swing: 0.5)
        XCTAssertEqual(half.frame(forTick: 0, sampleRate: sr), 0)
        XCTAssertEqual(half.frame(forTick: 1, sampleRate: sr), 14_000)
        XCTAssertEqual(half.frame(forTick: 2, sampleRate: sr), 24_000)   // beat 2 — unmoved

        // Full swing: off-beat at ⅔ · 24 000 = 16 000 (the triplet position).
        let full = MetronomeConfiguration(bpm: 120, subdivision: .eighth, swing: 1.0)
        XCTAssertEqual(full.frame(forTick: 0, sampleRate: sr), 0)
        XCTAssertEqual(full.frame(forTick: 1, sampleRate: sr), 16_000)
        XCTAssertEqual(full.frame(forTick: 2, sampleRate: sr), 24_000)   // beat 2 — unmoved
        XCTAssertEqual(full.frame(forTick: 3, sampleRate: sr), 40_000)   // beat 2 + ⅔ beat
    }

    /// Swung sixteenths: within each eighth the odd sixteenth ("e"/"a") moves to ⅔ of that eighth, while
    /// the beat AND the "and" (the on-eighth pulses at even positions) stay exactly on the straight grid.
    func testSwungSixteenthFramesKeepOnPulsesFixed() {
        let sr = 48_000.0
        let full = MetronomeConfiguration(bpm: 120, subdivision: .sixteenth, swing: 1.0)
        // 6 000 frames/tick straight, 24 000 frames/beat.
        XCTAssertEqual(full.frame(forTick: 0, sampleRate: sr), 0)        // beat
        XCTAssertEqual(full.frame(forTick: 1, sampleRate: sr), 8_000)    // "e" → ⅔ of the first eighth
        XCTAssertEqual(full.frame(forTick: 2, sampleRate: sr), 12_000)   // "and" (on-eighth) — unmoved
        XCTAssertEqual(full.frame(forTick: 3, sampleRate: sr), 20_000)   // "a" → ⅔ of the second eighth
        XCTAssertEqual(full.frame(forTick: 4, sampleRate: sr), 24_000)   // next beat — unmoved
    }

    /// Swing only touches eighth and sixteenth divisions; a triplet (or any tuplet) is left straight even
    /// at full swing.
    func testSwingDoesNotAffectTriplets() {
        let sr = 48_000.0
        let straight = MetronomeConfiguration(bpm: 120, subdivision: .triplet, swing: 0)
        let swung = MetronomeConfiguration(bpm: 120, subdivision: .triplet, swing: 1.0)
        for n in 0...12 {
            XCTAssertEqual(swung.frame(forTick: n, sampleRate: sr),
                           straight.frame(forTick: n, sampleRate: sr),
                           "triplet tick \(n) must not swing")
        }
    }

    func testSwingIsClampedToUnitRange() {
        XCTAssertEqual(MetronomeConfiguration(subdivision: .eighth, swing: 5).swing, 1.0)
        XCTAssertEqual(MetronomeConfiguration(subdivision: .eighth, swing: -3).swing, 0.0)
    }

    // MARK: - Idiomatic cells (which sixteenth sub-positions sound — pure, no audio)

    func testCellSilencesExactlyTheNonSoundingSixteenths() {
        // 4/4 sixteenths (tpb 4), default accents [strong, normal, medium, normal].
        func level(_ cell: RhythmCell, _ tick: Int) -> AccentLevel {
            MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .sixteenth, cell: cell)
                .accentLevel(forTick: tick)
        }

        // Dotted-8th + 16th = [0, 3]: only the beat and the last sixteenth sound.
        XCTAssertEqual(level(.dottedEighthSixteenth, 0), .strong)
        XCTAssertEqual(level(.dottedEighthSixteenth, 1), .muted)
        XCTAssertEqual(level(.dottedEighthSixteenth, 2), .muted)
        XCTAssertEqual(level(.dottedEighthSixteenth, 3), .weak)

        // Gallop = [0, 2, 3].
        XCTAssertEqual(level(.gallop, 0), .strong)
        XCTAssertEqual(level(.gallop, 1), .muted)
        XCTAssertEqual(level(.gallop, 2), .weak)
        XCTAssertEqual(level(.gallop, 3), .weak)

        // Reverse gallop = [0, 1, 3].
        XCTAssertEqual(level(.reverseGallop, 0), .strong)
        XCTAssertEqual(level(.reverseGallop, 1), .weak)
        XCTAssertEqual(level(.reverseGallop, 2), .muted)
        XCTAssertEqual(level(.reverseGallop, 3), .weak)

        // Straight (Off): every sixteenth sounds.
        XCTAssertEqual(level(.straight, 1), .weak)
        XCTAssertEqual(level(.straight, 2), .weak)
    }

    /// The cell's downbeat (position 0) keeps its beat accent on every beat, so it is always emphasised
    /// over the cell's inner (weak) sixteenths.
    func testCellDownbeatCarriesTheBeatAccent() {
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .sixteenth,
                                       cell: .gallop)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)   // beat 1 head
        XCTAssertEqual(c.accentLevel(forTick: 8), .medium)   // beat 3 head (default 4/4 medium)
        XCTAssertEqual(c.beatIndex(forTick: 8), 2)
    }

    /// A cell is inert unless the sixteenth subdivision is active — selecting one on an eighth pulse
    /// silences nothing.
    func testCellIsInertOffTheSixteenthGrid() {
        let c = MetronomeConfiguration(bpm: 120, timeSignature: .common, subdivision: .eighth,
                                       cell: .gallop)
        XCTAssertEqual(c.accentLevel(forTick: 0), .strong)
        XCTAssertEqual(c.accentLevel(forTick: 1), .weak, "no sixteenth grid → the cell silences nothing")
    }

    /// The audio path (`RenderPlan`) must mirror the pure config exactly for a swung AND celled config —
    /// same frames, same accents, same beat indices — so what the accuracy tests prove about the config is
    /// what the engine renders. (Extends `testRenderPlanMatchesConfiguration` to the new parameters.)
    func testRenderPlanMatchesConfigurationWithSwingAndCell() {
        let sr = 44_100.0
        let swung = MetronomeConfiguration(bpm: 143, timeSignature: .common, subdivision: .sixteenth,
                                           swing: 0.7, cell: .gallop)
        let plan = RenderPlan(config: swung, sampleRate: sr)
        for n in 0...2000 {
            XCTAssertEqual(plan.frame(forTick: n), swung.frame(forTick: n, sampleRate: sr), "frame \(n)")
            XCTAssertEqual(plan.accentLevel(forTick: n), swung.accentLevel(forTick: n), "accent \(n)")
            XCTAssertEqual(plan.beatIndex(forTick: n), swung.beatIndex(forTick: n), "beatIndex \(n)")
        }
    }
}
