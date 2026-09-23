import XCTest
@testable import Metronome

final class MeterInterpretationTests: XCTestCase {
    func testCompoundBeatUnitsAcrossDenominators() {
        for (denominator, name) in [(2, "Dotted whole"), (4, "Dotted half"),
                                    (8, "Dotted quarter"), (16, "Dotted eighth")] {
            for (numerator, beats) in [(6, 2), (9, 3), (12, 4)] {
                let meter = TimeSignature(numerator: numerator, denominator: denominator)
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
        let half = TimeSignature(numerator: 6, denominator: 4)
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
        vm.setGroupedBeats(false)
        XCTAssertEqual(vm.config.beatsPerBar, 6)
        XCTAssertEqual(vm.config.bpm, 120)
    }

    func testUnavailablePickupDoesNotShiftOneClickBarBeforeZero() {
        let config = MetronomeConfiguration(bpm: 60, timeSignature: TimeSignature(numerator: 1, denominator: 4))
        let plan = RenderPlan(config: config, sampleRate: 48_000, pickup: Pickup(ticks: 10))
        XCTAssertEqual(plan.frame(forTick: 0), 0)
        XCTAssertEqual(plan.frame(forTick: 1), 48_000)
    }
}
