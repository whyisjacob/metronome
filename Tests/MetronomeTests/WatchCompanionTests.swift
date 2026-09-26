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

    func testSongStartLabelFollowsSyncedSelection() throws {
        XCTAssertEqual(settings().startTitle, "Start")
        let selected = settings(song: Song(name: "Practice", sections: [SongSection(name: "Verse", bars: 1)]))
        let synced = try WatchSnapshot.decode(JSONEncoder().encode(selected))
        XCTAssertEqual(synced.startTitle, "Start Song")
        XCTAssertEqual(synced.song?.name, "Practice")
    }

    func testSelectedSongClickTimbreReachesAudioOutput() throws {
        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: 48_000)
        defer { engine.teardownOfflineRendering() }
        let song = Song(name: "Click test", sections: [SongSection(name: "A", tempoBPM: 120, bars: 1)])
        engine.setSongSound(.classic)
        let classic = try engine.renderOfflineSong(song)
        engine.setSongSound(.woodblock)
        let woodblock = try engine.renderOfflineSong(song)
        XCTAssertEqual(classic.count, woodblock.count)
        XCTAssertTrue(woodblock.contains { abs($0) > 0.001 })
        XCTAssertNotEqual(Array(classic.prefix(2_400)), Array(woodblock.prefix(2_400)))
    }

    func testWatchSoundChoicesMapToAllEngineSoundsAndPreserveSavedModes() {
        XCTAssertNil(WatchOutput.vibration.sound)
        XCTAssertEqual(WatchOutput(rawValue: "vibration"), .vibration)
        XCTAssertEqual(WatchOutput(rawValue: "voice"), .voice)
        XCTAssertEqual(Set(WatchOutput.allCases.compactMap(\.sound)), Set(MetronomeSound.allCases))
    }

    func testWatchSoundChoiceOverridesSongVoiceWithoutChangingItsGrid() {
        let original = Song(name: "Practice", sections: [
            SongSection(name: "Verse", tempoBPM: 100, subdivision: .eighth, bars: 1,
                        voiceEnabled: true, speakSubdivisions: false)
        ], tempoScale: 1.2, pickupTicks: 1, voiceEnabled: true)
        for output in WatchOutput.allCases {
            let song = output.playbackSong(original)
            XCTAssertEqual(song.sections[0].tempoBPM, 120)
            XCTAssertEqual(song.sections[0].subdivision, .eighth)
            XCTAssertEqual(song.pickupTicks, 1)
            XCTAssertEqual(song.voiceEnabled, output == .voice)
            XCTAssertEqual(song.sections[0].voiceEnabled, output == .voice)
            XCTAssertEqual(song.sections[0].speakSubdivisions, output == .voice)
        }
        XCTAssertEqual(original.sections[0].tempoBPM, 100)
        XCTAssertEqual(original.sections[0].speakSubdivisions, false)
    }

    func testSyncedManualSubdivisionsProduceEveryTick() throws {
        for subdivision in Subdivision.allCases {
            for meter in [TimeSignature.common, TimeSignature(numerator: 6, denominator: 8)] {
                let config = MetronomeConfiguration(bpm: 92, timeSignature: meter, subdivision: subdivision)
                let synced = try WatchSnapshot.decode(JSONEncoder().encode(settings(config: config)))
                let clock = WatchBeatClock(snapshot: synced)
                for tick in 0..<(config.ticksPerBar * 3) {
                    let onset = Double(config.frame(forTick: tick, sampleRate: 48_000)) / 48_000
                    let beat = clock.beat(at: onset + 0.000001)
                    XCTAssertEqual(beat?.serial, tick, "\(subdivision), \(meter)")
                    XCTAssertEqual(beat?.number, (tick / config.ticksPerBeat) % config.beatsPerBar + 1)
                    XCTAssertEqual(beat?.time ?? -1, onset, accuracy: 0.000001)
                }
            }
        }
    }

    func testSwungSubdivisionPickupAndLatePollKeepTheirGrid() {
        let config = MetronomeConfiguration(bpm: 120, subdivision: .eighth, swing: 1)
        let clock = WatchBeatClock(snapshot: settings(config: config, pickup: 1))
        XCTAssertEqual(clock.beat(at: 0)?.number, 4)
        XCTAssertTrue(clock.beat(at: 0)?.leadIn == true)
        XCTAssertEqual(clock.beat(at: 0.16668)?.number, 1)
        XCTAssertFalse(clock.beat(at: 0.16668)?.leadIn == true)
        XCTAssertEqual(clock.beat(at: 0.49)?.serial, 1)
        XCTAssertEqual(clock.beat(at: 0.50001)?.serial, 2)
        XCTAssertEqual(clock.beat(at: 500.50001)?.serial, 2002)
    }

    func testSongSubdivisionChangesRetainOffbeatPickupAndSectionBoundaries() throws {
        let song = Song(name: "Subdivisions", sections: [
            SongSection(name: "Eighths", tempoBPM: 120, subdivision: .eighth, bars: 1),
            SongSection(name: "Triplets", tempoBPM: 60, subdivision: .triplet, bars: 1)
        ], pickupTicks: 1)
        let synced = try WatchSnapshot.decode(JSONEncoder().encode(settings(song: song)))
        let clock = WatchBeatClock(snapshot: synced)
        XCTAssertEqual(clock.beat(at: 0)?.number, 4)
        XCTAssertTrue(clock.beat(at: 0)?.leadIn == true)
        XCTAssertEqual(clock.beat(at: 0.25)?.serial, 1)
        XCTAssertEqual(clock.beat(at: 0.5)?.serial, 2)
        XCTAssertEqual(clock.beat(at: 0.5)?.number, 1)
        XCTAssertEqual(clock.beat(at: 2.25)?.section, 1)
        XCTAssertEqual(clock.beat(at: 2.584)?.serial, 10)
        XCTAssertEqual(clock.beat(at: 2.917)?.serial, 11)
        XCTAssertEqual(clock.beat(at: 3.25)?.number, 2)
        XCTAssertNil(clock.beat(at: 6.25))
    }

    func testMutedBeatAlsoMutesItsHapticSubdivisions() {
        let config = MetronomeConfiguration(bpm: 120, subdivision: .eighth,
                                            accents: [.strong, .muted, .normal, .normal])
        let clock = WatchBeatClock(snapshot: settings(config: config))
        XCTAssertFalse(clock.beat(at: 0.25)?.muted == true)
        XCTAssertTrue(clock.beat(at: 0.5)?.muted == true)
        XCTAssertTrue(clock.beat(at: 0.75)?.muted == true)
        XCTAssertFalse(clock.beat(at: 1)?.muted == true)
    }

    func testSnapshotPreservesSongAndRejectsIncompatibleVersion() throws {
        let original = settings(song: Song(name: "Test", sections: [SongSection(name: "Verse", bars: 64)]))
        XCTAssertEqual(try WatchSnapshot.decode(JSONEncoder().encode(original)), original)
        var future = original
        future.schema = 99
        XCTAssertThrowsError(try WatchSnapshot.decode(JSONEncoder().encode(future)))
    }
}
