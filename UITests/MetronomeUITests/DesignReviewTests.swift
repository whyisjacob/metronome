import XCTest

final class DesignReviewTests: XCTestCase {
    func testCompoundTempoUnitCanBeChosenExplicitly() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Maelzel"].waitForExistence(timeout: 30))
        let numerator = app.pickerWheels["Time signature numerator"]
        for _ in 0..<5 where !numerator.isHittable { app.swipeUp() }
        XCTAssertTrue(numerator.isHittable)
        numerator.adjust(toPickerWheelValue: "6")
        let unit = app.segmentedControls["tempo-beat-unit"]
        for _ in 0..<3 where !unit.isHittable { app.swipeUp() }
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

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
