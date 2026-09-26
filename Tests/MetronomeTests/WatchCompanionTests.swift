import XCTest
@testable import Metronome

final class WatchCompanionTests: XCTestCase {
    private func settings(config: MetronomeConfiguration = MetronomeConfiguration(bpm: 120),
                          song: Song? = nil, pickup: Int = 0) -> WatchSnapshot {
        WatchSnapshot(revision: 1, config: config, song: song, pickupTicks: pickup)
    }

    func testLateHapticPollSkipsAheadWithoutAccumulatedDrift() {
        let clock = WatchBeatClock(snapshot: settings())
        XCTAssertEqual(clock.beat(at: 0)?.number, 1)
        XCTAssertEqual(clock.beat(at: 0.51)?.number, 2)
        let late = clock.beat(at: 500.01)
        XCTAssertEqual(late?.number, 1)
        XCTAssertEqual(late?.bar, 251)
        XCTAssertEqual(late?.serial, 1000)
        XCTAssertEqual(late?.time, 500)
    }

    func testManualPickupCountsTailThenFirstDownbeat() {
        let clock = WatchBeatClock(snapshot: settings(pickup: 2))
        XCTAssertEqual(clock.beat(at: 0)?.number, 3)
        XCTAssertEqual(clock.beat(at: 0.5)?.number, 4)
        XCTAssertTrue(clock.beat(at: 0.5)?.leadIn == true)
        XCTAssertEqual(clock.beat(at: 1)?.number, 1)
        XCTAssertFalse(clock.beat(at: 1)?.leadIn == true)
    }

    func testSongChangesMeterTempoAndStopsAtEnd() {
        let song = Song(name: "Watch", sections: [
            SongSection(name: "A", tempoBPM: 120, bars: 1),
            SongSection(name: "B", tempoBPM: 60, timeSignature: TimeSignature(numerator: 3, denominator: 4), bars: 1)
        ], pickupTicks: 2)
        let clock = WatchBeatClock(snapshot: settings(song: song))
        XCTAssertEqual(clock.beat(at: 0)?.number, 3)
        XCTAssertEqual(clock.beat(at: 1)?.number, 1)
        XCTAssertEqual(clock.beat(at: 3)?.section, 1)
        XCTAssertEqual(clock.beat(at: 5)?.number, 3)
        XCTAssertEqual(clock.duration, 6)
        XCTAssertNil(clock.beat(at: 6))
    }

    func testCompoundMeterKeepsDottedQuarterCount() {
        let config = MetronomeConfiguration(bpm: 120, timeSignature: TimeSignature(numerator: 6, denominator: 8))
        let clock = WatchBeatClock(snapshot: settings(config: config))
        XCTAssertEqual(clock.beat(at: 0.5)?.number, 2)
        XCTAssertEqual(clock.beat(at: 1)?.number, 1)
        XCTAssertEqual(clock.beat(at: 1)?.bar, 2)
    }

    func testDelayedReleaseCannotCancelNewOwner() {
        var ownership = WatchOwnership()
        let old = ownership.claim()
        let current = ownership.claim()
        XCTAssertFalse(ownership.release(old))
        XCTAssertEqual(ownership.token, current)
        XCTAssertTrue(ownership.release(current))
        XCTAssertNil(ownership.token)
    }

    func testSnapshotPreservesSongAndRejectsIncompatibleVersion() throws {
        let original = settings(song: Song(name: "Test", sections: [SongSection(name: "Verse", bars: 64)]))
        XCTAssertEqual(try WatchSnapshot.decode(JSONEncoder().encode(original)), original)
        var future = original
        future.schema = 99
        XCTAssertThrowsError(try WatchSnapshot.decode(JSONEncoder().encode(future)))
    }
}
