import XCTest
import Foundation
@testable import Metronome

/// The mute / silent-practice MODEL: the three `OutputChannels`, the `MutePreset` compositions, and
/// `MuteSettingsStore` persistence through an injected `UserDefaults` suite. Pure — no engine, no audio.
/// Every preset's channel map is hand-derived from the spec ("just count" = click muted + voice; "just
/// flash" = silent + visual), never read back from the type under test.
final class MuteModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MuteSettingsTests-\(UUID().uuidString)")!
    }

    // MARK: - OutputChannels

    func testFullIsEverythingOn() {
        XCTAssertEqual(OutputChannels.full, OutputChannels(click: true, voice: true, visual: true))
        XCTAssertTrue(OutputChannels.full.isFull)
        XCTAssertTrue(OutputChannels.full.anyAudioOn)
    }

    func testAnyAudioOnIgnoresVisual() {
        // Flash-only (silent, visual on) reads as "no audio"; visual is not audio.
        XCTAssertFalse(OutputChannels(click: false, voice: false, visual: true).anyAudioOn)
        XCTAssertTrue(OutputChannels(click: true, voice: false, visual: false).anyAudioOn)
        XCTAssertTrue(OutputChannels(click: false, voice: true, visual: false).anyAudioOn)
    }

    func testOutputChannelsCodableRoundTrip() throws {
        for c in [OutputChannels.full,
                  OutputChannels(click: false, voice: true, visual: true),
                  OutputChannels(click: false, voice: false, visual: true),
                  OutputChannels(click: true, voice: false, visual: false)] {
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(OutputChannels.self, from: data), c)
        }
    }

    // MARK: - MutePreset — hand-derived channel maps

    func testPresetChannelMapsAreExactlyAsSpecified() {
        XCTAssertEqual(MutePreset.full.channels,      OutputChannels(click: true,  voice: true,  visual: true))
        XCTAssertEqual(MutePreset.countOnly.channels, OutputChannels(click: false, voice: true,  visual: true))
        XCTAssertEqual(MutePreset.flashOnly.channels, OutputChannels(click: false, voice: false, visual: true))
    }

    func testCountOnlyMutesClickAndKeepsVoice() {
        let c = MutePreset.countOnly.channels
        XCTAssertFalse(c.click, "Count only mutes the click")
        XCTAssertTrue(c.voice, "Count only keeps the spoken count")
        XCTAssertTrue(c.visual)
    }

    func testFlashOnlyIsFullySilentWithVisualOn() {
        let c = MutePreset.flashOnly.channels
        XCTAssertFalse(c.anyAudioOn, "Flash only is silent")
        XCTAssertTrue(c.visual, "Flash only keeps the on-screen beat")
    }

    func testEveryPresetKeepsTheVisualOn() {
        for p in MutePreset.allCases { XCTAssertTrue(p.channels.visual, "\(p) must keep the visual on") }
    }

    func testMatchingRoundTripsPresetsAndIsNilForCustom() {
        for p in MutePreset.allCases { XCTAssertEqual(MutePreset.matching(p.channels), p) }
        // Custom combinations (a visual-off, or click-only) are not named presets.
        XCTAssertNil(MutePreset.matching(OutputChannels(click: true, voice: true, visual: false)))
        XCTAssertNil(MutePreset.matching(OutputChannels(click: true, voice: false, visual: true)))
    }

    func testPresetsHaveDistinctNamesAndNonEmptyLabels() {
        XCTAssertEqual(Set(MutePreset.allCases.map(\.displayName)).count, MutePreset.allCases.count)
        for p in MutePreset.allCases {
            XCTAssertFalse(p.displayName.isEmpty)
            XCTAssertFalse(p.symbolName.isEmpty)
            XCTAssertFalse(p.statusLabel.isEmpty)
        }
    }

    func testMutePresetCodableRoundTrip() throws {
        for p in MutePreset.allCases {
            let data = try JSONEncoder().encode(p)
            XCTAssertEqual(try JSONDecoder().decode(MutePreset.self, from: data), p)
        }
    }

    // MARK: - MuteSettingsStore persistence (the required round-trip)

    func testDefaultsAreEverythingOn() {
        let store = MuteSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.channels, .full)
    }

    func testCountOnlyPersistsAcrossFreshStore() {
        let defaults = makeDefaults()
        MuteSettingsStore(defaults: defaults).setChannels(MutePreset.countOnly.channels)

        let reloaded = MuteSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.channels, MutePreset.countOnly.channels)
        XCTAssertFalse(reloaded.channels.click)
        XCTAssertTrue(reloaded.channels.voice)
        XCTAssertTrue(reloaded.channels.visual)
    }

    func testFlashOnlyPersistsAcrossFreshStore() {
        let defaults = makeDefaults()
        MuteSettingsStore(defaults: defaults).setChannels(MutePreset.flashOnly.channels)

        let reloaded = MuteSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.channels, MutePreset.flashOnly.channels)
        XCTAssertFalse(reloaded.channels.anyAudioOn)
        XCTAssertTrue(reloaded.channels.visual)
    }

    func testVisualOffPersistsIndependently() {
        let defaults = makeDefaults()
        MuteSettingsStore(defaults: defaults)
            .setChannels(OutputChannels(click: true, voice: true, visual: false))
        let reloaded = MuteSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.channels.visual)
        XCTAssertTrue(reloaded.channels.click)
        XCTAssertTrue(reloaded.channels.voice)
    }
}
