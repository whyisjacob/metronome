import XCTest
@testable import Metronome

final class MeterInterpretationTests: XCTestCase {
    func testCompoundQuarterAndSixteenthMetersInRenderedAudio() throws {
        for (numerator, denominator, beats) in [(6, 4, 2), (9, 16, 3)] {
            let config = MetronomeConfiguration(bpm: 120,
                timeSignature: TimeSignature(numerator: numerator, denominator: denominator, groupedBeats: true),
                subdivision: .eighth)
            let engine = MetronomeEngine()
            try engine.prepareForOfflineRendering(sampleRate: 48_000)
            defer { engine.teardownOfflineRendering() }
            let samples = try engine.renderOffline(config: config, seconds: Double(beats) + 0.05)
            let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: 864)
            // Two bars at dotted-note = 120: each main beat lasts 24,000 frames,
            // each denominator-note division 8,000 frames. Include the next downbeat.
            XCTAssertEqual(onsets.count, numerator * 2 + 1)
            for (tick, frame) in onsets.enumerated() {
                XCTAssertLessThanOrEqual(abs(frame - tick * 8_000), 1)
            }
        }
    }

    func testCompoundBeatUnitsAcrossDenominators() {
        for (denominator, name) in [(2, "Dotted whole"), (4, "Dotted half"),
                                    (8, "Dotted quarter"), (16, "Dotted eighth")] {
            for (numerator, beats) in [(6, 2), (9, 3), (12, 4)] {
                let meter = TimeSignature(numerator: numerator, denominator: denominator, groupedBeats: true)
                XCTAssertEqual(meter.beatsPerBar, beats)
                XCTAssertEqual(meter.beatUnitName, name)
                let config = MetronomeConfiguration(bpm: 60, timeSignature: meter, subdivision: .eighth)
                XCTAssertEqual(config.ticksPerBar, numerator)
                // One dotted beat per second, with three equal denominator-note divisions.
                XCTAssertEqual(config.secondsPerTick, 1.0 / 3.0)
                XCTAssertEqual(config.frame(forTick: numerator, sampleRate: 48_000), beats * 48_000)
            }
        }
    }

    func testSubdivisionNamesFollowCompoundDivisionUnit() {
        let half = TimeSignature(numerator: 6, denominator: 4, groupedBeats: true)
        XCTAssertEqual(Subdivision.eighth.displayName(in: half), "Quarters")
        XCTAssertEqual(Subdivision.sixteenth.displayName(in: half), "Eighths")
        XCTAssertEqual(Subdivision.thirtysecond.displayName(in: half), "Sixteenths")
        let eighth = TimeSignature(numerator: 9, denominator: 16)
        XCTAssertEqual(Subdivision.eighth.displayName(in: eighth), "Sixteenths")
        XCTAssertEqual(Subdivision.sixteenth.displayName(in: eighth), "32nds")
        XCTAssertEqual(Subdivision.thirtysecond.ticksPerBeat(compound: true), 12)
        XCTAssertEqual(Set(Subdivision.compoundCases.map { $0.ticksPerBeat(compound: true) }), [1, 3, 5, 6, 7, 12])
    }

    func testExplicitDenominatorCountingAndFastTripleMeter() {
        let six = TimeSignature(numerator: 6, denominator: 8, groupedBeats: false)
        XCTAssertEqual(six.beatsPerBar, 6)
        XCTAssertEqual(six.beatUnitName, "Eighth note")
        XCTAssertEqual(Subdivision.eighth.displayName(in: six), "Sixteenth")
        XCTAssertEqual(TimeSignature(numerator: 3, denominator: 8).beatsPerBar, 3)
        let one = TimeSignature(numerator: 3, denominator: 8, groupedBeats: true)
        XCTAssertEqual(one.beatsPerBar, 1)
        XCTAssertEqual(one.beatUnitName, "Dotted quarter")
        XCTAssertFalse(TimeSignature(numerator: 7, denominator: 8, groupedBeats: true).groupedBeats)
    }

    func testLegacyMetersKeepTheirOriginalPlaybackMeaning() throws {
        for (n, d, beats, grouped) in [(6, 4, 6, false), (9, 16, 9, false),
                                      (6, 8, 2, true), (3, 8, 3, false)] {
            let data = Data("{\"numerator\":\(n),\"denominator\":\(d)}".utf8)
            let meter = try JSONDecoder().decode(TimeSignature.self, from: data)
            XCTAssertEqual(meter.beatsPerBar, beats)
            XCTAssertEqual(meter.groupedBeats, grouped)
            XCTAssertEqual(try JSONDecoder().decode(TimeSignature.self,
                from: JSONEncoder().encode(meter)), meter)
        }
    }

    func testNewMeterChoiceSurvivesSongSharing() throws {
        for grouped in [false, true] {
            let meter = TimeSignature(numerator: 6, denominator: 4, groupedBeats: grouped)
            let song = Song(name: "Meter", sections: [SongSection(timeSignature: meter, subdivision: .eighth)])
            let imported = try SongTransfer.decode(SongTransfer.encode(song))
            XCTAssertEqual(imported.sections[0].timeSignature, meter)
            XCTAssertEqual(imported.durationSeconds, song.durationSeconds)
        }
    }

    func testDecodedInvalidMeterIsValidated() throws {
        let data = Data("{\"numerator\":0,\"denominator\":0,\"groupedBeats\":true}".utf8)
        let meter = try JSONDecoder().decode(TimeSignature.self, from: data)
        XCTAssertEqual(meter.numerator, 1)
        XCTAssertEqual(meter.denominator, 4)
        XCTAssertFalse(meter.groupedBeats)
    }

    @MainActor
    func testChangingBeatUnitResetsDivisionAccentsAndClampsPickup() {
        let vm = MetronomeViewModel(config: MetronomeConfiguration(
            timeSignature: TimeSignature(numerator: 6, denominator: 4, groupedBeats: false),
            subdivision: .sixteenth))
        vm.setPickupTicks(10)
        vm.setGroupedBeats(true)
        XCTAssertEqual(vm.config.beatsPerBar, 2)
        XCTAssertEqual(vm.config.subdivision, .quarter)
        XCTAssertEqual(vm.config.accents, [.strong, .medium])
        XCTAssertEqual(vm.pickupTicks, 1)
        // ♩=92 → dotted half = 92/3: same quarter-note speed, now counted in two.
        XCTAssertEqual(vm.config.bpm, 92.0 / 3.0, accuracy: 1e-9)
        vm.setGroupedBeats(false)
        XCTAssertEqual(vm.config.beatsPerBar, 6)
        XCTAssertEqual(vm.config.bpm, 92, accuracy: 1e-9)
    }

    /// Music theory: a metronome mark names a note value, and changing how the bar is counted must not
    /// change how long the written notes last. So the BPM rescales by (old beat ÷ new beat).
    @MainActor
    func testChangingCountedNoteKeepsWrittenNoteDurations() {
        let vm = MetronomeViewModel(config: MetronomeConfiguration(bpm: 92, timeSignature: .common))
        vm.setDenominator(2)                                   // 4/4 ♩=92 → 4/2 𝅗𝅥=46
        XCTAssertEqual(vm.config.timeSignature.beatsPerBar, 4)
        XCTAssertEqual(vm.config.bpm, 46, accuracy: 1e-9)
        XCTAssertEqual(vm.config.secondsPerBeat, 2 * 60.0 / 92, accuracy: 1e-12)   // half = two quarters
        vm.setDenominator(4)                                   // and back
        XCTAssertEqual(vm.config.bpm, 92, accuracy: 1e-9)

        vm.setNumerator(6)                                     // 6/4: still quarters → tempo unchanged
        XCTAssertEqual(vm.config.timeSignature.beatsPerBar, 6)
        XCTAssertEqual(vm.config.bpm, 92, accuracy: 1e-9)

        let eighths = MetronomeViewModel(config: MetronomeConfiguration(bpm: 120,
            timeSignature: TimeSignature(numerator: 3, denominator: 8)))
        eighths.setNumerator(6)                                // 3/8 ♪=120 → 6/8 dotted ♩=40
        XCTAssertEqual(eighths.config.timeSignature.beatsPerBar, 2)
        XCTAssertEqual(eighths.config.bpm, 40, accuracy: 1e-9)
    }

    func testSimpleMeterBeatUnitIsTheDenominator() {
        for (n, d, beats, seconds) in [(4, 2, 4, 1.0), (3, 2, 3, 1.0), (2, 2, 2, 1.0), (4, 4, 4, 1.0),
                                       (6, 4, 6, 1.0), (7, 8, 7, 1.0), (5, 16, 5, 1.0)] {
            let config = MetronomeConfiguration(bpm: 60, timeSignature: TimeSignature(numerator: n, denominator: d))
            XCTAssertEqual(config.beatsPerBar, beats, "\(n)/\(d)")
            XCTAssertEqual(config.secondsPerBeat, seconds, "\(n)/\(d): BPM counts the \(d == 2 ? "half" : "denominator") note")
        }
    }

    func testUnavailablePickupDoesNotShiftOneClickBarBeforeZero() {
        let config = MetronomeConfiguration(bpm: 60, timeSignature: TimeSignature(numerator: 1, denominator: 4))
        let plan = RenderPlan(config: config, sampleRate: 48_000, pickup: Pickup(ticks: 10))
        XCTAssertEqual(plan.frame(forTick: 0), 0)
        XCTAssertEqual(plan.frame(forTick: 1), 48_000)
    }
}
