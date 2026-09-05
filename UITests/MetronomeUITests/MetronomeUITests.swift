import XCTest

/// Launches the app on a simulator, navigates the real SwiftUI screens via their actual controls, and
/// captures a full-screen screenshot of each key screen as a `.keepAlways` `XCTAttachment`. CI
/// (`.github/workflows/screenshots.yml`) then extracts those attachments from the `.xcresult` into
/// downloadable PNGs — the whole point being to let a Windows-only owner *see* the rendered app, at the
/// exact App Store 6.9" pixel size, without a Mac.
///
/// Design notes:
///  - **Non-asserting on navigation:** every step is guarded with `waitForExistence` and simply skipped
///    (never failed) if an element is missing, so a hiccup on one screen still yields screenshots of every
///    screen we *could* reach. The presence / absence of each named PNG in the artifact is the signal for
///    which screens were reachable. (`continueAfterFailure = true` reinforces this.)
///  - **No real-time audio.** The test never starts the single-tempo click, because a headless CI
///    simulator's real-time audio engine may not start — and `MetronomeViewModel.start()` deliberately
///    stays stopped (does not flip `isPlaying`) when it can't, so a "running" state isn't reliable there.
///    The beat visual is drawn even when stopped (idle pattern), so the hero shot still shows it. Song
///    playback is different: `playSong(...)` is explicitly headless-safe (it sets its state regardless of
///    whether the engine started), so the song now-playing screen is reliably reachable.
///
/// Labels used below were verified against the current views (Sept 2026):
///   header `Text("MAELZEL")`; tab `Songs`; nav bars `Songs` / `Edit Song` / `Settings`; buttons
///   `Settings`, `Add song`, `Done` (builder + settings), `Play <song name>`, `Exit song`.
final class MetronomeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureKeyScreens() throws {
        // (01) Main metronome screen — the default (first) tab on launch: the "MAELZEL" header, the beat
        //      visual, the mute / silent-practice presets, tempo and Start. Ignore the wait result: if the
        //      marker never appears we still snapshot whatever rendered, so the artifact is never empty.
        _ = app.staticTexts["MAELZEL"].waitForExistence(timeout: 30)
        capture("01-Metronome-Main")

        // (02) Scroll the main screen to reveal the meter (time-signature) + subdivision + sound controls
        //      that sit below the beat visual, then snapshot them. Best-effort: a blind swipe is enough for
        //      a screenshot, and if there's no scroll view we just re-shoot the top.
        let mainScroll = app.scrollViews.firstMatch
        if mainScroll.waitForExistence(timeout: 5) {
            mainScroll.swipeUp()
        }
        capture("02-Meter-And-Controls")
        // Return to the top so later navigation (the header Settings button) starts from a known position.
        if mainScroll.exists {
            mainScroll.swipeDown()
            mainScroll.swipeDown()
        }

        // (03) Settings — the depth of the app (voice, groove, accents, visuals, the gap trainer, the song
        //      launcher…) behind the header's slider button. Dismiss it before moving on (it's a sheet over
        //      the whole app, so it must be closed before switching tabs).
        let settingsButton = app.buttons["Settings"]
        if settingsButton.waitForExistence(timeout: 10) {
            settingsButton.tap()
            let settingsNav = app.navigationBars["Settings"]
            if settingsNav.waitForExistence(timeout: 15) {
                capture("03-Settings")
                settingsNav.buttons["Done"].tap()
            }
        }

        // (04) Song builder — the Songs tab's "+" creates a "New Song" (with one "Section 1") and presents
        //      the builder sheet titled "Edit Song". The song is persisted the instant it's created (the
        //      builder auto-saves), so the library will have a playable row regardless of how we dismiss.
        let songsTab = app.tabBars.buttons["Songs"]
        guard songsTab.waitForExistence(timeout: 15) else {
            capture("99-tab-bar-missing")
            return
        }
        songsTab.tap()
        _ = app.navigationBars["Songs"].waitForExistence(timeout: 15)

        let addSong = app.buttons["Add song"]
        if addSong.waitForExistence(timeout: 10) {
            addSong.tap()
            let builderNav = app.navigationBars["Edit Song"]
            if builderNav.waitForExistence(timeout: 15) {
                capture("04-Song-Builder")
                // The builder auto-saves every edit; its only toolbar dismiss control is "Done".
                builderNav.buttons["Done"].tap()
            }
        }

        // (05) Song now-playing — tapping a library row's play button loads the song on the SHARED
        //      metronome and reveals the Metronome tab (there is no separate player); the single-tempo
        //      controls are replaced in place by the song's now-playing view (title, section list, master
        //      tempo, transport, "Exit song"). `playSong` is headless-safe, so this is reliably reachable.
        let play = app.buttons["Play New Song"].firstMatch
        if play.waitForExistence(timeout: 10) {
            play.tap()
            let exit = app.buttons["Exit song"]
            if exit.waitForExistence(timeout: 15) {
                capture("05-Song-NowPlaying")
                exit.tap()
            }
        }
    }

    /// Captures the whole screen and attaches it, kept regardless of test outcome so CI can extract it as a
    /// PNG at the device's native pixel size (iPhone 16 Pro Max = 1320 × 2868, an accepted App Store 6.9").
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
