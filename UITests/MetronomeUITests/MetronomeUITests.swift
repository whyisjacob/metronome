import XCTest

/// Launches the app on a simulator, navigates the real SwiftUI screens via their actual controls, and
/// captures a full-screen screenshot of each key screen as a `.keepAlways` `XCTAttachment`. CI
/// (`.github/workflows/screenshots.yml`) then extracts those attachments from the `.xcresult` into
/// downloadable PNGs — the whole point being to let a Windows-only owner *see* the rendered app, at the
/// exact App Store iPhone screenshot sizes (the workflow captures both the 6.5" 1284×2778 and 6.9"
/// 1320×2868 classes), without a Mac.
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
///    playback still loads the song if audio cannot start, but correctly remains stopped and displays an
///    error. A screenshot alone is not evidence that audio playback succeeded.
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
        //      visual, tempo, and Start. (Silent practice now lives in Settings; the main screen shows only
        //      a tiny "Silent" tag under Start when audio is muted.) Ignore the wait result: if the marker
        //      never appears we still snapshot whatever rendered, so the artifact is never empty.
        _ = app.staticTexts["MAELZEL"].waitForExistence(timeout: 30)
        capture("01-Metronome-Main")

        // (02) Scroll the main screen to reveal the meter (time-signature) + subdivision controls that sit
        //      below the beat visual, then snapshot them.
        //
        //      NOT a blind `swipeUp()`: that over-scrolls and parks the Time-signature CARD TITLE flush
        //      under the status bar, where "TIME SIGNATURE" collides with the status-bar clock ("9:41").
        //      Instead do ONE controlled, low-inertia drag of ~38% of the screen height, which lands the
        //      meter card a comfortable distance below the status bar with the subdivision grid still in
        //      frame. The touch-down point (dy 0.72) is the meter card's title / the gap above it in the
        //      un-scrolled layout — below the Start button and above the numerator/denominator wheels (both
        //      of which sit elsewhere at rest) — so the gesture pans the scroll view rather than pressing a
        //      button or spinning a wheel. Best-effort: if there's no scroll view we just re-shoot the top.
        let mainScroll = app.scrollViews.firstMatch
        if mainScroll.waitForExistence(timeout: 5) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
            start.press(forDuration: 0.1, thenDragTo: end)
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

        // ================================================================================================
        // Applicable feature screens for App Store panels 06 / 07 / 08. Each is a REAL, reachable screen in
        // the shipping app (verified Sept 2026 against the SwiftUI views), captured so those panels show the
        // feature they name instead of reusing the meter (02) / settings (03) / song-builder (04) shots.
        // Same best-effort, non-asserting style: every step is guarded and simply skipped if an element is
        // missing, so one screen failing never blocks the others. The (04)/(05) steps above already created
        // and left "New Song" in the library, which shot 08 relies on.
        // ================================================================================================

        // Land on the Metronome tab, scrolled to the top, so the header Settings button and the main-screen
        // scroll both start from a known position (the (05) "Exit song" already returns us here).
        if app.tabBars.buttons["Metronome"].waitForExistence(timeout: 10) {
            app.tabBars.buttons["Metronome"].tap()
        }
        let baseScroll = app.scrollViews.firstMatch
        _ = baseScroll.waitForExistence(timeout: 5)

        // (06-Sounds) The Sound picker (Click / Woodblock / Beep / Rimshot / Cowbell / Voice) lives on the
        //      main screen in the "Sound" card, near the bottom of the scroll (below Count-in). Scroll it into
        //      view via its unique "Woodblock" button, then snapshot — the "choose your sound" half of the
        //      "Timing & feel" panel. (Shot 02's controlled drag deliberately stops above this card.)
        if baseScroll.exists {
            var down = 0
            while !app.buttons["Woodblock"].isHittable && down < 6 { baseScroll.swipeUp(); down += 1 }
        }
        if app.buttons["Woodblock"].waitForExistence(timeout: 3) {
            capture("06-Sounds")
        }
        // Scroll back up until the header Settings button is reachable again.
        if baseScroll.exists {
            var up = 0
            while !app.buttons["Settings"].isHittable && up < 6 { baseScroll.swipeDown(); up += 1 }
        }

        // (06-Groove) Swing + idiomatic rhythm-cell "feel" controls — the strongest "Timing & feel" shot.
        //      They live in the collapsed "Groove" section of Settings; open Settings, expand Groove, snapshot.
        if openSettings() {
            expandSettingsSection("Groove")
            _ = app.sliders.firstMatch.waitForExistence(timeout: 3)   // the swing slider rendered
            capture("06-Groove")
            dismissSettings()
        }

        // (07-GapTrainer) The gap-click practice trainer — its own Settings section with a real ACTIVE state.
        //      Expand it and switch it ON so the mode picker (Random / Bars) and its controls are shown — the
        //      actual practice tool "in action", not the generic collapsed settings list of shot 03.
        if openSettings() {
            expandSettingsSection("Gap trainer")
            let enable = app.switches["Silence beats to practise internal time"]
            var t = 0
            while !enable.isHittable && t < 3 { app.scrollViews.firstMatch.swipeUp(); t += 1 }
            if enable.exists, enable.isHittable, (enable.value as? String) != "1" { enable.tap() }
            _ = app.switches["Keep a soft downbeat"].waitForExistence(timeout: 3)   // enabled controls rendered
            capture("07-GapTrainer")
            dismissSettings()
        }

        // (08-SongLibrary) The saved-songs list (the Songs tab) — distinct from the song BUILDER captured in
        //      (04). "New Song" is saved by now, so the library shows a real, playable card with its
        //      section / bar / duration summary. Switch to the Songs tab and snapshot the list.
        if songsTab.waitForExistence(timeout: 10) {
            songsTab.tap()
            if app.navigationBars["Songs"].waitForExistence(timeout: 10) {
                _ = app.buttons["Play New Song"].firstMatch.waitForExistence(timeout: 5)
                capture("08-SongLibrary")
            }
        }
    }

    /// Captures the whole screen and attaches it, kept regardless of test outcome so CI can extract it as a
    /// PNG at the device's native pixel size (the workflow runs this on a 6.5" device → 1284 × 2778 and a
    /// 6.9" device → 1320 × 2868, both accepted App Store iPhone sizes).
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Navigation helpers for the feature screens (06–08)

    /// Opens the unified Settings sheet from the main-screen header button (accessibilityLabel "Settings");
    /// returns true once its navigation bar appears.
    @discardableResult
    private func openSettings() -> Bool {
        let button = app.buttons["Settings"]
        guard button.waitForExistence(timeout: 10) else { return false }
        button.tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: 15)
    }

    /// Dismisses the Settings sheet via its "Done" toolbar button. It's a sheet over the whole app, so it
    /// must be closed before switching tabs or opening it again.
    private func dismissSettings() {
        let done = app.navigationBars["Settings"].buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// Expands a collapsible Settings section by its title. Each accordion header is a Button whose
    /// accessibility label is the section name (see `CollapsibleSection`), so `app.buttons[title]` finds it;
    /// scroll it into view first for a section that sits below the fold (e.g. "Gap trainer").
    private func expandSettingsSection(_ title: String) {
        let header = app.buttons[title]
        var tries = 0
        while !header.isHittable && tries < 6 { app.scrollViews.firstMatch.swipeUp(); tries += 1 }
        if header.waitForExistence(timeout: 5), header.isHittable { header.tap() }
    }
}
