import XCTest
import Foundation
@testable import Metronome

/// `SoundSettingsStore` persistence — the audio preferences that survive relaunch: the chosen sound and,
/// for Voice, whether the subdivisions are spoken. Uses an injected `UserDefaults` suite so each test is
/// isolated.
final class SoundSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SoundSettingsTests-\(UUID().uuidString)")!
    }

    func testDefaultsAreClassicAndSpeakSubdivisionsOn() {
        let store = SoundSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.sound, .classic)
        XCTAssertTrue(store.speakSubdivisions)
    }

    func testSoundPersistsAcrossFreshStore() {
        let defaults = makeDefaults()
        SoundSettingsStore(defaults: defaults).setSound(.voice)

        let reloaded = SoundSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.sound, .voice)
    }

    func testEverySoundRoundTrips() {
        for sound in MetronomeSound.allCases {
            let defaults = makeDefaults()
            SoundSettingsStore(defaults: defaults).setSound(sound)
            XCTAssertEqual(SoundSettingsStore(defaults: defaults).sound, sound, "sound \(sound) did not persist")
        }
    }

    func testSpeakSubdivisionsPersistsAcrossFreshStore() {
        let defaults = makeDefaults()
        SoundSettingsStore(defaults: defaults).setSpeakSubdivisions(false)

        let reloaded = SoundSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.speakSubdivisions)
    }

    /// An *absent* key must read as "on" (not the `false` that `bool(forKey:)` would return), so a fresh
    /// install counts the full "1 e and a" out of the box.
    func testAbsentSpeakSubdivisionsDefaultsOn() {
        let defaults = makeDefaults()
        SoundSettingsStore(defaults: defaults).setSound(.beep)   // touch the store, but not the speak key
        XCTAssertTrue(SoundSettingsStore(defaults: defaults).speakSubdivisions)
    }
}
