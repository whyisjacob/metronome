import XCTest
import Foundation
@testable import Metronome

/// Tests for the Recents feature: the tempo-independent uniqueness key, the precise `remember` rules
/// (BPM-only → in-place update; any non-BPM change → unique entry with move-to-top dedup), the 5-item
/// cap, and JSON round-trip persistence.
final class RecentsStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentsStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func config(bpm: Double = 120,
                        numerator: Int = 4,
                        denominator: Int = 4,
                        subdivision: Subdivision = .quarter,
                        accents: [BeatAccent]? = nil,
                        sound: MetronomeSound = .classic) -> MetronomeConfiguration {
        MetronomeConfiguration(
            bpm: bpm,
            timeSignature: TimeSignature(numerator: numerator, denominator: denominator),
            subdivision: subdivision,
            accents: accents,
            sound: sound
        )
    }

    // MARK: - Uniqueness key (everything EXCEPT bpm)

    func testSettingsKeyIgnoresBPMButDistinguishesEveryOtherField() {
        // Same settings, different tempo → identical key (so a BPM change is not a new recent).
        XCTAssertEqual(config(bpm: 120).settingsKey, config(bpm: 240).settingsKey)

        // Each non-BPM field changes the key.
        XCTAssertNotEqual(config(numerator: 4).settingsKey, config(numerator: 5).settingsKey)
        XCTAssertNotEqual(config(denominator: 4).settingsKey, config(denominator: 8).settingsKey)
        XCTAssertNotEqual(config(subdivision: .quarter).settingsKey, config(subdivision: .eighth).settingsKey)
        XCTAssertNotEqual(config(sound: .classic).settingsKey, config(sound: .voice).settingsKey)
        XCTAssertNotEqual(config(accents: [true, false, false, false]).settingsKey,
                          config(accents: [true, false, true, false]).settingsKey)
    }

    // MARK: - remember(): first insert and no-op

    func testFreshStoreIsEmpty() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(RecentsStore(directory: dir).recents.isEmpty)
    }

    func testFirstRememberInserts() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)
        store.remember(config())
        XCTAssertEqual(store.recents.count, 1)
    }

    func testRememberingIdenticalConfigDoesNotDuplicate() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)
        let c = config(bpm: 120)
        store.remember(c)
        store.remember(c)
        XCTAssertEqual(store.recents.count, 1)
    }

    // MARK: - BPM-only change updates the top entry in place (no new entry, no reorder)

    func testBPMOnlyChangeUpdatesTopInPlace() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(bpm: 120))
        store.remember(config(bpm: 140))   // same settings, tempo only
        store.remember(config(bpm: 96))    // same settings, tempo only

        XCTAssertEqual(store.recents.count, 1, "BPM-only changes must not add entries")
        XCTAssertEqual(store.recents[0].config.bpm, 96, "the single entry tracks the latest BPM in place")
    }

    func testBPMChangeOnMatchingTopDoesNotReorder() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(bpm: 120, subdivision: .quarter))   // A → [A]
        store.remember(config(bpm: 130, subdivision: .eighth))    // B → [B, A]

        // Change ONLY B's tempo (B is the top). It must update in place, staying on top; A stays below.
        store.remember(config(bpm: 175, subdivision: .eighth))
        XCTAssertEqual(store.recents.count, 2)
        XCTAssertEqual(store.recents[0].config.subdivision, .eighth)
        XCTAssertEqual(store.recents[0].config.bpm, 175)
        XCTAssertEqual(store.recents[1].config.subdivision, .quarter)
    }

    // MARK: - Non-BPM change registers a unique recent

    func testNonBPMChangeCreatesNewEntryOnTop() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(bpm: 120, subdivision: .quarter))   // A
        store.remember(config(bpm: 130, subdivision: .eighth))    // B (subdivision changed)

        XCTAssertEqual(store.recents.count, 2)
        XCTAssertEqual(store.recents[0].config.subdivision, .eighth, "newest on top")
        XCTAssertEqual(store.recents[1].config.subdivision, .quarter)
    }

    func testSoundChangeRegistersUniqueRecent() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(sound: .classic))
        store.remember(config(sound: .woodblock))
        store.remember(config(sound: .voice))

        XCTAssertEqual(store.recents.count, 3)
        XCTAssertEqual(store.recents.map { $0.config.sound }, [.voice, .woodblock, .classic])
    }

    func testAccentChangeRegistersUniqueRecent() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(accents: [true, false, false, false]))
        store.remember(config(accents: [true, false, true, false]))
        XCTAssertEqual(store.recents.count, 2)
    }

    // MARK: - Dedup: re-selecting an existing config moves it to the top with the new BPM

    func testReselectingExistingConfigMovesToTopAndUpdatesBPM() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        store.remember(config(bpm: 120, subdivision: .quarter))   // A → [A]
        store.remember(config(bpm: 130, subdivision: .eighth))    // B → [B, A]

        // Re-select A's settings with a different tempo: A moves to the top and its BPM updates.
        store.remember(config(bpm: 155, subdivision: .quarter))

        XCTAssertEqual(store.recents.count, 2, "re-selecting must not duplicate")
        XCTAssertEqual(store.recents[0].config.subdivision, .quarter)
        XCTAssertEqual(store.recents[0].config.bpm, 155)
        XCTAssertEqual(store.recents[1].config.subdivision, .eighth)
    }

    // MARK: - Cap at 5 unique, oldest dropped

    func testCapsAtFiveUniqueDroppingOldest() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(directory: dir)

        for n in [2, 3, 4, 5, 6, 7] {           // six distinct settings keys (by numerator)
            store.remember(config(numerator: n))
        }

        XCTAssertEqual(store.recents.count, RecentsStore.maxCount)
        XCTAssertEqual(store.recents.first?.config.timeSignature.numerator, 7, "newest on top")
        XCTAssertFalse(store.recents.contains { $0.config.timeSignature.numerator == 2 },
                       "the oldest unique setting is dropped past the cap")
    }

    // MARK: - Persistence

    func testPersistsAcrossFreshStore() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecentsStore(directory: dir)
        store.remember(config(bpm: 120, subdivision: .quarter))
        store.remember(config(bpm: 90, numerator: 7, denominator: 8, subdivision: .eighth, sound: .voice))

        let reloaded = RecentsStore(directory: dir)
        XCTAssertEqual(reloaded.recents, store.recents,
                       "a fresh store must read back exactly what was saved (ids, configs, order)")
    }

    func testClearEmptiesAndPersists() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecentsStore(directory: dir)
        store.remember(config())
        store.clear()
        XCTAssertTrue(store.recents.isEmpty)
        XCTAssertTrue(RecentsStore(directory: dir).recents.isEmpty)
    }
}
