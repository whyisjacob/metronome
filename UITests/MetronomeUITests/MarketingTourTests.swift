import XCTest

/// Walks the real app at a human pace while CI screen-records the simulator, for the launch video.
/// Prints "TOUR <step> <unix time>" markers so the editor can cut the recording without guessing.
/// Never asserts: a missing element just skips that beat of the tour.
final class MarketingTourTests: XCTestCase {
    private var app: XCUIApplication!

    private func mark(_ step: String) {
        print("TOUR \(step) \(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
    private func hold(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private func scrollMain() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45)))
    }
    private func scrollTop() {
        var up = 0
        while !app.buttons["Settings"].isHittable && up < 8 { app.scrollViews.firstMatch.swipeDown(); up += 1 }
    }

    func testMarketingTour() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        _ = app.staticTexts["Maelzel"].waitForExistence(timeout: 30)
        hold(1.5)
        mark("main")
        hold(2.5)

        // Voice sound: the app counts out loud.
        let voice = app.buttons["Voice"]
        var d = 0
        while !voice.isHittable && d < 8 { scrollMain(); d += 1 }
        mark("sound-card")
        hold(1.0)
        if voice.isHittable { voice.tap() }
        mark("voice-selected")
        hold(1.5)
        scrollTop()
        hold(0.8)

        // Tap tempo.
        let tap = app.buttons["Tap tempo"]
        var tt = 0
        while tap.exists && !tap.isHittable && tt < 4 { scrollMain(); tt += 1 }
        if tap.waitForExistence(timeout: 3), tap.isHittable {
            mark("tap-tempo")
            for _ in 0..<5 { tap.tap(); hold(0.42) }
            hold(1.0)
            scrollTop()
        }

        // Start.
        let start = app.buttons["Start"]
        if start.waitForExistence(timeout: 5) { start.tap() }
        hold(0.5)
        mark(app.buttons["Stop"].exists ? "playing-yes" : "playing-no")
        hold(5.0)

        // Subdivisions: eighths, then triplets.
        let eighth = app.buttons["subdivision-eighth"]
        d = 0
        while !eighth.isHittable && d < 6 { scrollMain(); d += 1 }
        if eighth.isHittable { eighth.tap(); mark("eighths") }
        hold(4.0)
        let trip = app.buttons["subdivision-triplet"]
        if trip.isHittable { trip.tap(); mark("triplets") }
        hold(4.0)

        // Odd meter: 7/8.
        let num = app.pickerWheels.element(boundBy: 0)
        d = 0
        while !num.isHittable && d < 5 { scrollMain(); d += 1 }
        if num.isHittable {
            mark("meter")
            num.adjust(toPickerWheelValue: "7")
            hold(0.8)
            let den = app.pickerWheels.element(boundBy: 1)
            if den.isHittable { den.adjust(toPickerWheelValue: "8") }
            mark("seven-eight")
            hold(5.0)
        }
        scrollTop()
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        hold(1.0)

        // Song mode.
        let songsTab = app.tabBars.buttons["Songs"]
        if songsTab.waitForExistence(timeout: 10) {
            songsTab.tap()
            let add = app.buttons["Add song"]
            if add.waitForExistence(timeout: 10) {
                add.tap()
                if app.navigationBars["Edit Song"].waitForExistence(timeout: 15) {
                    mark("builder")
                    hold(2.0)
                    let addSection = app.buttons["Add section"]
                    if addSection.waitForExistence(timeout: 3) {
                        if !addSection.isHittable { app.swipeUp() }
                        addSection.tap(); hold(1.2)
                        if addSection.isHittable { addSection.tap() }
                        mark("sections-added")
                        hold(2.5)
                    }
                    app.navigationBars["Edit Song"].buttons["Done"].tap()
                }
            }
            hold(1.5)
            let play = app.buttons["Play New Song"].firstMatch
            if play.waitForExistence(timeout: 10) {
                var w = 0
                while !play.isHittable && w < 10 { hold(0.5); w += 1 }
                if play.isHittable { play.tap() } else { play.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                if app.buttons["Exit song"].waitForExistence(timeout: 15) {
                    mark("song-now-playing")
                    hold(1.0)
                    let s2 = app.buttons["Start"]
                    if s2.exists { s2.tap() }
                    hold(6.0)
                    if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
                    hold(0.8)
                    app.buttons["Exit song"].tap()
                }
            }
        }

        // Gap trainer.
        let metroTab = app.tabBars.buttons["Metronome"]
        if metroTab.waitForExistence(timeout: 5) { metroTab.tap() }
        scrollTop()
        if app.buttons["Settings"].waitForExistence(timeout: 5) {
            app.buttons["Settings"].tap()
            if app.navigationBars["Settings"].waitForExistence(timeout: 10) {
                let header = app.buttons["Gap trainer"]
                var t = 0
                while !header.isHittable && t < 6 { app.scrollViews.firstMatch.swipeUp(); t += 1 }
                if header.isHittable { header.tap() }
                hold(1.0)
                let enable = app.switches["Silence beats to practise internal time"]
                t = 0
                while !enable.isHittable && t < 3 { app.scrollViews.firstMatch.swipeUp(); t += 1 }
                mark("gap-trainer")
                if enable.isHittable, (enable.value as? String) != "1" { enable.tap() }
                hold(3.5)
                app.navigationBars["Settings"].buttons["Done"].tap()
            }
        }
        // Run with gaps so the beat visual shows the dropped beats.
        scrollTop()
        if app.buttons["Start"].waitForExistence(timeout: 5) { app.buttons["Start"].tap() }
        mark("gap-running")
        hold(8.0)
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        mark("end")
        hold(1.0)
    }
}
