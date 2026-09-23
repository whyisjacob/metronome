import XCTest

final class DesignReviewTests: XCTestCase {
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
