import XCTest

/// Launches the app on a simulator, navigates the real UI via its actual controls, and captures a
/// full-screen screenshot of each key screen as a `.keepAlways` `XCTAttachment`. CI
/// (`.github/workflows/screenshots.yml`) then extracts those attachments from the `.xcresult` into
/// downloadable PNGs — the whole point being to let a Windows-only owner *see* the rendered SwiftUI
/// without a Mac.
///
/// Design notes:
///  - This test is deliberately **non-asserting** about navigation: every step is guarded with
///    `waitForExistence` and simply skipped (not failed) if an element is missing, so a hiccup on
///    one screen still yields screenshots of every screen we *could* reach. The presence / absence
///    of each named PNG in the artifact is the signal for which screens were reachable.
///  - It never starts playback, so it never touches the audio hardware (which a headless CI
///    simulator lacks). See `MetronomeViewModel` / `SongPlayerViewModel`: audio is only engaged on
///    `start()`, never on view appearance.
final class MetronomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureKeyScreens() throws {
        // (a) Main metronome screen — the default (first) tab on launch.
        //     Ignore the wait result: if the marker never appears we still snapshot whatever
        //     rendered, so the artifact is never empty.
        _ = app.staticTexts["METRONOME"].waitForExistence(timeout: 30)
        capture("01-Metronome")

        // (b) Song Library — switch to the "Songs" tab. On a fresh install this shows the empty
        //     state ("No songs yet").
        let songsTab = app.tabBars.buttons["Songs"]
        guard songsTab.waitForExistence(timeout: 15) else {
            capture("99-tab-bar-missing")
            return
        }
        songsTab.tap()
        _ = app.navigationBars["Songs"].waitForExistence(timeout: 15)
        capture("02-SongLibrary-Empty")

        // (c) Song Builder — the "+" toolbar button creates a "New Song" (with one "Section 1")
        //     and presents the builder sheet titled "Edit Song".
        let addSong = app.buttons["Add song"]
        if addSong.waitForExistence(timeout: 10) {
            addSong.tap()
            _ = app.navigationBars["Edit Song"].waitForExistence(timeout: 15)
            capture("03-SongBuilder")

            // (c') Section editor — tap the first section row to open "Edit Section".
            let sectionRow = app.buttons["song-section-row"].firstMatch
            if sectionRow.waitForExistence(timeout: 10) {
                sectionRow.tap()
            } else if app.staticTexts["Section 1"].waitForExistence(timeout: 5) {
                app.staticTexts["Section 1"].tap()   // fallback: hit-test into the row via its text
            }
            if app.navigationBars["Edit Section"].waitForExistence(timeout: 15) {
                capture("04-SongSectionEditor")
                app.navigationBars["Edit Section"].buttons["Cancel"].tap()
            }

            // Commit the song so the library has a playable row to open the Play screen from.
            let save = app.navigationBars["Edit Song"].buttons["Save"]
            if save.waitForExistence(timeout: 10) { save.tap() }
        }

        // Populated library (nice-to-have, shows a real song row).
        if app.navigationBars["Songs"].waitForExistence(timeout: 10) {
            capture("05-SongLibrary")
        }

        // (d) Song Play — the row's play button opens the full-screen player ("Done" + "Start").
        let play = app.buttons["Play New Song"].firstMatch
        if play.waitForExistence(timeout: 10) {
            play.tap()
            if app.buttons["Done"].waitForExistence(timeout: 15) {
                capture("06-SongPlay")
                app.buttons["Done"].tap()
            }
        }
    }

    /// Captures the whole screen and attaches it, kept regardless of test outcome so CI can extract
    /// it as a PNG.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
