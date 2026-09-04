import XCTest
import Foundation
@testable import Metronome

/// The visual-preferences model: the indicator-style enum, the flash palette, the accent→colour
/// selection rule, and `VisualSettingsStore` persistence through an injected `UserDefaults` suite.
final class VisualSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "VisualSettingsTests-\(UUID().uuidString)")!
    }

    // MARK: - Indicator style enum

    func testIndicatorStyleHasFourStableCases() {
        XCTAssertEqual(BeatIndicatorStyle.allCases.count, 4)
        XCTAssertEqual(BeatIndicatorStyle.allCases.map(\.rawValue), ["ball", "dots", "counter", "ring"])
        for style in BeatIndicatorStyle.allCases {
            XCTAssertEqual(BeatIndicatorStyle(rawValue: style.rawValue), style)
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.symbolName.isEmpty)
        }
    }

    func testIndicatorStyleCodableRoundTrip() throws {
        for style in BeatIndicatorStyle.allCases {
            let data = try JSONEncoder().encode(style)
            XCTAssertEqual(try JSONDecoder().decode(BeatIndicatorStyle.self, from: data), style)
        }
    }

    func testFlashColorPaletteIsCodable() throws {
        XCTAssertGreaterThanOrEqual(FlashColor.allCases.count, 6)
        for c in FlashColor.allCases {
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(FlashColor.self, from: data), c)
        }
    }

    // MARK: - Accent → flash colour selection (pure)

    func testFlashColorSelectionByAccent() {
        // Accented (downbeat) clicks use the accent colour; normal + subdivision clicks use the normal one.
        XCTAssertEqual(VisualSettingsStore.flashColor(for: .strong, accent: .red, normal: .blue), .red)
        XCTAssertEqual(VisualSettingsStore.flashColor(for: .normal, accent: .red, normal: .blue), .blue)
        XCTAssertEqual(VisualSettingsStore.flashColor(for: .weak, accent: .red, normal: .blue), .blue)
    }

    // MARK: - Store defaults + persistence

    func testDefaultsAreBallAndFlashOff() {
        let store = VisualSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.indicatorStyle, .ball)
        XCTAssertFalse(store.borderFlashEnabled)
        XCTAssertEqual(store.accentFlashColor, .orange)
        XCTAssertEqual(store.normalFlashColor, .blue)
    }

    func testSettingsPersistAcrossFreshStore() {
        let defaults = makeDefaults()
        let store = VisualSettingsStore(defaults: defaults)
        store.setIndicatorStyle(.ring)
        store.setBorderFlashEnabled(true)
        store.setAccentFlashColor(.red)
        store.setNormalFlashColor(.teal)

        let reloaded = VisualSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.indicatorStyle, .ring)
        XCTAssertTrue(reloaded.borderFlashEnabled)
        XCTAssertEqual(reloaded.accentFlashColor, .red)
        XCTAssertEqual(reloaded.normalFlashColor, .teal)
    }

    func testChangingStyleUpdatesPublishedValue() {
        let store = VisualSettingsStore(defaults: makeDefaults())
        store.setIndicatorStyle(.counter)
        XCTAssertEqual(store.indicatorStyle, .counter)
        store.setIndicatorStyle(.dots)
        XCTAssertEqual(store.indicatorStyle, .dots)
    }
}
