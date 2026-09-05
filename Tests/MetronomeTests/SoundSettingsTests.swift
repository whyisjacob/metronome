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

    /// Voice volume defaults to full (1.0), persists across a fresh store, and clamps to 0…1.
    func testVoiceVolumeDefaultsFullAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(SoundSettingsStore(defaults: defaults).voiceVolume, 1.0, accuracy: 1e-9)

        SoundSettingsStore(defaults: defaults).setVoiceVolume(0.4)
        XCTAssertEqual(SoundSettingsStore(defaults: defaults).voiceVolume, 0.4, accuracy: 1e-9)
    }

    /// An *absent* voice-volume key must read as 1.0 (not the 0.0 `double(forKey:)` would give), so the
    /// voice is not silent out of the box.
    func testAbsentVoiceVolumeDefaultsFull() {
        let defaults = makeDefaults()
        SoundSettingsStore(defaults: defaults).setSound(.beep)   // touch the store, but not the volume key
        XCTAssertEqual(SoundSettingsStore(defaults: defaults).voiceVolume, 1.0, accuracy: 1e-9)
    }

    func testVoiceVolumeClampsToUnitRange() {
        let defaults = makeDefaults()
        let store = SoundSettingsStore(defaults: defaults)
        store.setVoiceVolume(5)
        XCTAssertEqual(store.voiceVolume, 1.0, accuracy: 1e-9)
        store.setVoiceVolume(-3)
        XCTAssertEqual(store.voiceVolume, 0.0, accuracy: 1e-9)
    }
}
