import XCTest
@testable import Metronome

/// Integration-contract tests for the "one app, one engine" song redesign.
///
/// These prove the architectural fixes, not just the audio math:
///  (a) starting a song drives the SAME `MetronomeViewModel` — its tempo/meter/subdivision follow the
///      song per section as the engine reports position — rather than a second player/engine;
///  (c) editing a section round-trips through the SAME `MetronomeConfiguration` the shared main-screen
///      controls bind to (the section editor reuses those controls; this is their data contract).
///
/// `@MainActor` because `MetronomeViewModel` is main-actor isolated.
@MainActor
final class SongIntegrationTests: XCTestCase {

    private func sampleSong() -> Song {
        Song(name: "Test", sections: [
            SongSection(name: "A", tempoBPM: 120, timeSignature: .common, subdivision: .quarter),
            SongSection(name: "B", tempoBPM: 90,
                        timeSignature: TimeSignature(numerator: 3, denominator: 4), subdivision: .eighth),
            SongSection(name: "C", tempoBPM: 144,
                        timeSignature: TimeSignature(numerator: 7, denominator: 8), subdivision: .quarter),
        ])
    }

    // MARK: - (a) One shared view-model / engine drives the song per section

    func testPlayingASongDrivesTheSameViewModelPerSection() {
        let vm = MetronomeViewModel()
        let baselineBPM = vm.bpm            // the single-tempo default
        let song = sampleSong()

        vm.playSong(song)
        XCTAssertEqual(vm.activeSong?.id, song.id,
                       "playSong loads the song into the SAME view-model — there is no separate player")

        // As the engine reports each section, this ONE view-model's tempo/meter/subdivision follow it.
        vm.updateSongPosition(sectionIndex: 0, bar: 1)
        XCTAssertEqual(vm.bpm, 120)
        XCTAssertEqual(vm.timeSignature, .common)
        XCTAssertEqual(vm.subdivision, .quarter)
        XCTAssertEqual(vm.currentSongSection?.name, "A")

        vm.updateSongPosition(sectionIndex: 1, bar: 2)
        XCTAssertEqual(vm.bpm, 90, "the SAME view-model's tempo changed to section B as the song advanced")
        XCTAssertEqual(vm.timeSignature, TimeSignature(numerator: 3, denominator: 4))
        XCTAssertEqual(vm.subdivision, .eighth)
        XCTAssertEqual(vm.currentSongSection?.name, "B")
        XCTAssertEqual(vm.currentSongBar, 2)

        vm.updateSongPosition(sectionIndex: 2, bar: 1)
        XCTAssertEqual(vm.bpm, 144)
        XCTAssertEqual(vm.timeSignature, TimeSignature(numerator: 7, denominator: 8))
        XCTAssertNil(vm.nextSongSection, "C is the last section")

        // Exiting returns the SAME view-model to the single-tempo click.
        vm.exitSong()
        XCTAssertNil(vm.activeSong)
        XCTAssertEqual(vm.bpm, baselineBPM,
                       "after exit the shared view-model reflects the single-tempo config again")
    }

    /// The beat visual the main screen renders follows the current section's meter/subdivision — the same
    /// screen shows the song, not a separate player view.
    func testVisualStateFollowsTheCurrentSection() {
        let vm = MetronomeViewModel()
        let song = sampleSong()
        vm.playSong(song)

        vm.updateSongPosition(sectionIndex: 0, bar: 1)      // A: 4/4 quarter
        XCTAssertEqual(vm.visualState.beatsPerMeasure, 4)
        XCTAssertEqual(vm.visualState.ticksPerBeat, 1)

        vm.updateSongPosition(sectionIndex: 1, bar: 1)      // B: 3/4 eighth
        XCTAssertEqual(vm.visualState.beatsPerMeasure, 3)
        XCTAssertEqual(vm.visualState.ticksPerBeat, 2)
    }

    func testEmptySongIsNotPlayable() {
        let vm = MetronomeViewModel()
        vm.playSong(Song(name: "Empty", sections: []))
        XCTAssertNil(vm.activeSong, "a song with no sections must not enter song mode")
    }

    // MARK: - (c) Editing a section round-trips through the shared controls' configuration

    /// `SongSection.configuration` (what the shared controls edit) and `updating(from:...)` (the save side)
    /// are exact inverses — so editing a section through the reused main-screen controls never loses data.
    func testSectionRoundTripsThroughSharedConfiguration() {
        let original = SongSection(name: "Verse", tempoBPM: 128,
                                   timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                   subdivision: .eighth, accentPattern: [.strong, .medium],
                                   bars: 4, repeatCount: 2, swing: 0.5, cell: .straight)

        let config = original.configuration
        XCTAssertEqual(config.bpm, 128)
        XCTAssertEqual(config.timeSignature, TimeSignature(numerator: 6, denominator: 8))
        XCTAssertEqual(config.subdivision, .eighth)
        XCTAssertEqual(config.swing, 0.5, accuracy: 1e-9)

        let rebuilt = original.updating(from: config, name: original.name,
                                        bars: original.bars, repeatCount: original.repeatCount)
        XCTAssertEqual(rebuilt, original, "round-tripping a section through its configuration is lossless")
    }

    /// The REAL editor path: seed a `MetronomeViewModel` from a section (as `SongSectionEditorView` does),
    /// edit via the SAME control methods the main screen calls, then rebuild the section — the edits land.
    func testEditingViaSharedControlsAppliesToTheSection() {
        let section = SongSection(id: UUID(), name: "Verse", tempoBPM: 120, timeSignature: .common,
                                  subdivision: .quarter, bars: 4, repeatCount: 1)
        let editVM = MetronomeViewModel(config: section.configuration)   // what the editor seeds

        editVM.setBPM(150)
        editVM.setSubdivision(.eighth)
        editVM.setSwing(0.6)   // self-activates the eighth grid (already eighth)

        let c = editVM.config
        let edited = SongSection(id: section.id, name: "Verse", tempoBPM: c.bpm,
                                 timeSignature: c.timeSignature, subdivision: c.subdivision,
                                 accentPattern: c.accents, bars: 4, repeatCount: 1,
                                 swing: c.swing, cell: c.cell)

        XCTAssertEqual(edited.id, section.id, "editing keeps the section's identity")
        XCTAssertEqual(edited.tempoBPM, 150)
        XCTAssertEqual(edited.subdivision, .eighth)
        XCTAssertEqual(edited.swing, 0.6, accuracy: 1e-9)
    }
}
