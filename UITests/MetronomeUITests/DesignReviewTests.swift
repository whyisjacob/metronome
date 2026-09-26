import XCTest

final class DesignReviewTests: XCTestCase {
    func testSubdivisionNotationCapture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Maelzel"].waitForExistence(timeout: 30))
        let last = app.buttons["subdivision-thirtysecond"]
        for _ in 0..<6 where !last.isHittable { scrollMain(app) }
        XCTAssertTrue(last.isHittable)
        XCTAssertTrue(app.buttons["subdivision-triplet"].exists)
        app.buttons["subdivision-sixteenth"].tap()
        capture("Subdivision-note-values", app)
    }

    func testACompoundTempoUnitCanBeChosenExplicitly() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Maelzel"].waitForExistence(timeout: 30))
        // SwiftUI applies the accessible label to the Picker container, not its wheel.
        // The main meter presents numerator first, denominator second.
        let numerator = app.pickerWheels.element(boundBy: 0)
        for _ in 0..<5 where !numerator.isHittable { scrollMain(app) }
        XCTAssertTrue(numerator.isHittable)
        numerator.adjust(toPickerWheelValue: "6")
        let unit = app.segmentedControls["tempo-beat-unit"]
        for _ in 0..<3 where !unit.isHittable { scrollMain(app) }
        XCTAssertTrue(unit.waitForExistence(timeout: 5))
        XCTAssertTrue(unit.buttons["Dotted half"].isSelected)
        XCTAssertTrue(app.staticTexts["2 beats per bar · dotted half beat"].exists)
        capture("Theory-6-4-grouped", app)
        unit.buttons["Quarter note"].tap()
        XCTAssertTrue(app.staticTexts["6 beats per bar · quarter note beat"].exists)
        capture("Theory-6-4-quarter", app)
    }

    func testAllVisualStylesRemainAvailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Maelzel"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Start metronome"].exists)
        capture("01-Main", app)
        for style in ["ball", "dots", "counter", "ring"] {
            app.buttons["Settings"].tap()
            let visuals = app.buttons["Visuals"]
            XCTAssertTrue(visuals.waitForExistence(timeout: 10))
            for _ in 0..<4 where !visuals.isHittable { app.swipeUp() }
            XCTAssertTrue(visuals.isHittable)
            visuals.tap()
            let option = app.buttons["visual-style-\(style)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            for _ in 0..<3 where !option.isHittable { app.swipeUp() }
            option.tap()
            capture("Settings-\(style)", app)
            app.navigationBars["Settings"].buttons["Done"].tap()
            XCTAssertTrue(app.buttons["Start metronome"].waitForExistence(timeout: 10))
            capture("Style-\(style)", app)
        }
    }

    private func scrollMain(_ app: XCUIApplication) {
        // Drag the margin so scrolling cannot accidentally rotate a meter wheel.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo:
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.4)))
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
