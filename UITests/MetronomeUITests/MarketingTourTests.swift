import XCTest

/// Walks the real app at a human pace while CI screen-records the simulator, for the launch video.
/// Prints "TOUR <step> <unix time>" markers so the editor can cut the recording without guessing.
final class MarketingTourTests: XCTestCase {
    private var app: XCUIApplication!
    private func mark(_ step: String) { print("TOUR \(step) \(String(format: "%.3f", Date().timeIntervalSince1970))") }
    private func hold(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    private func scrollMain() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45)))
    }
    private func scrollTop() {
        var up = 0
        while !app.buttons["Settings"].isHittable && up < 8 { app.scrollViews.firstMatch.swipeDown(); up += 1 }
        app.scrollViews.firstMatch.swipeDown()
    }
    private func openSettings() -> Bool {
        scrollTop()
        let b = app.buttons["Settings"]
        guard b.waitForExistence(timeout: 5), b.isHittable else { mark("settings-missing"); return false }
        b.tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: 10)
    }
    private func closeSettings() {
        let d = app.navigationBars["Settings"].buttons["Done"]
        if d.waitForExistence(timeout: 5) { d.tap() }
        hold(0.8)
    }

    func testMarketingTour() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        _ = app.staticTexts["Maelzel"].waitForExistence(timeout: 30)
        hold(1.0)

        // Setup (not filmed): Ball visual style and the Voice sound.
        if openSettings() {
            let visuals = app.buttons["Visuals"]
            var t = 0
            while !visuals.isHittable && t < 4 { app.swipeUp(); t += 1 }
            if visuals.isHittable { visuals.tap() }
            let ball = app.buttons["visual-style-ball"]
            if ball.waitForExistence(timeout: 5) {
                t = 0; while !ball.isHittable && t < 3 { app.swipeUp(); t += 1 }
                ball.tap(); mark("ball-set")
            }
            closeSettings()
        }
        let voice = app.buttons["Voice"]
        var d = 0
        while !voice.isHittable && d < 8 { scrollMain(); d += 1 }
        if voice.isHittable { voice.tap(); mark("voice-set") }
        hold(0.5)
        scrollTop()
        hold(1.5)

        // 1. Counting out loud in 4/4.
        mark("main")
        hold(1.5)
        app.buttons["Start"].tap()
        hold(0.3)
        mark(app.buttons["Stop"].exists ? "playing-yes" : "playing-no")
        hold(7.0)

        // 2. Subdivisions.
        let eighth = app.buttons["subdivision-eighth"]
        d = 0; while !eighth.isHittable && d < 6 { scrollMain(); d += 1 }
        if eighth.isHittable { eighth.tap(); mark("eighths") }
        hold(4.5)
        let trip = app.buttons["subdivision-triplet"]
        if trip.isHittable { trip.tap(); mark("triplets") }
        hold(4.5)
        let quarter = app.buttons["subdivision-quarter"]
        if quarter.isHittable { quarter.tap() }

        // 3. Odd meter 7/8, then show the counter in 7.
        let num = app.pickerWheels.element(boundBy: 0)
        d = 0; while !num.isHittable && d < 5 { scrollMain(); d += 1 }
        if num.isHittable {
            mark("meter")
            num.adjust(toPickerWheelValue: "7"); hold(0.6)
            let den = app.pickerWheels.element(boundBy: 1)
            if den.isHittable { den.adjust(toPickerWheelValue: "8") }
            mark("seven-eight")
            hold(4.0)
        }
        scrollTop()
        mark("seven-eight-top")
        hold(6.0)
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        // Back to 4/4 for the rest.
        d = 0; while !num.isHittable && d < 5 { scrollMain(); d += 1 }
        if num.isHittable {
            num.adjust(toPickerWheelValue: "4"); hold(0.4)
            let den = app.pickerWheels.element(boundBy: 1)
            if den.isHittable { den.adjust(toPickerWheelValue: "4") }
        }
        scrollTop()
        hold(1.0)

        // 4. Song mode: two sections with different tempo and meter.
        let songsTab = app.tabBars.buttons["Songs"]
        if songsTab.waitForExistence(timeout: 10) {
            songsTab.tap()
            let add = app.buttons["Add song"]
            if add.waitForExistence(timeout: 10) {
                add.tap()
                if app.navigationBars["Edit Song"].waitForExistence(timeout: 15) {
                    mark("builder")
                    hold(1.5)
                    let addSection = app.buttons["Add section"]
                    if addSection.waitForExistence(timeout: 3) { addSection.tap(); mark("section-added") }
                    hold(1.5)
                    let s2 = app.staticTexts["Section 2"].firstMatch
                    if s2.waitForExistence(timeout: 3) {
                        s2.tap()
                        if app.navigationBars["Edit Section"].waitForExistence(timeout: 5) {
                            mark("edit-section")
                            hold(1.0)
                            let slider = app.sliders.firstMatch
                            if slider.exists { slider.adjust(toNormalizedSliderPosition: 0.42) }
                            hold(0.8)
                            let w = app.pickerWheels.element(boundBy: 0)
                            var k = 0; while w.exists && !w.isHittable && k < 3 { app.swipeUp(); k += 1 }
                            if w.isHittable { w.adjust(toPickerWheelValue: "3") }
                            mark("section2-edited")
                            hold(1.5)
                            app.navigationBars["Edit Section"].buttons["Done"].tap()
                            hold(1.5)
                        } else { mark("edit-section-missing") }
                    }
                    mark("builder-two-sections")
                    hold(2.5)
                    let playSong = app.buttons["Play song"]
                    var k = 0; while playSong.exists && !playSong.isHittable && k < 3 { app.swipeUp(); k += 1 }
                    if playSong.isHittable { playSong.tap(); mark("play-song-tapped") } else { mark("play-song-missing") }
                }
            }
            if app.buttons["Exit song"].waitForExistence(timeout: 15) {
                mark("song-now-playing")
                hold(1.0)
                if app.buttons["Start"].exists { app.buttons["Start"].tap(); mark("song-started") }
                hold(12.0)
                if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
                hold(0.6)
                app.buttons["Exit song"].tap()
                hold(1.0)
            } else { mark("now-playing-missing") }
        }

        // 5. Gap trainer.
        let metroTab = app.tabBars.buttons["Metronome"]
        if metroTab.waitForExistence(timeout: 5) { metroTab.tap() }
        hold(1.0)
        if openSettings() {
            let header = app.buttons["Gap trainer"]
            var t = 0
            while !header.isHittable && t < 6 { app.scrollViews.firstMatch.swipeUp(); t += 1 }
            if header.isHittable { header.tap() } else { mark("gap-header-missing") }
            hold(0.8)
            let enable = app.switches["Silence beats to practise internal time"]
            t = 0; while enable.exists && !enable.isHittable && t < 3 { app.scrollViews.firstMatch.swipeUp(); t += 1 }
            mark("gap-trainer")
            if enable.isHittable, (enable.value as? String) != "1" { enable.tap(); mark("gap-on") }
            hold(3.0)
            closeSettings()
        }
        scrollTop()
        if app.buttons["Start"].waitForExistence(timeout: 5) { app.buttons["Start"].tap() }
        mark("gap-running")
        hold(12.0)
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        mark("end")
        hold(1.0)
    }
}
