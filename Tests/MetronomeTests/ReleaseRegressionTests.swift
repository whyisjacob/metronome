import XCTest
@testable import Metronome

final class ReleaseRegressionTests: XCTestCase {
    func testImportRejectsUnrelatedJSONAndBrokenWrappers() {
        for json in ["{}", "[]", "{\"name\":\"Not a song\"}",
                     "{\"song\":null}", "{\"song\":{}}",
                     "{\"song\":{\"sections\":\"broken\"},\"sections\":[]}",
                     "{\"song\":{\"sections\":[]},\"version\":\"broken\"}"] {
            XCTAssertThrowsError(try SongTransfer.decode(Data(json.utf8)), json)
        }
    }

    func testImportPreservesValidEmptySongAndLegacySong() throws {
        let empty = try SongTransfer.decode(Data("{\"name\":\"Draft\",\"sections\":[]}".utf8))
        XCTAssertEqual(empty.name, "Draft")
        XCTAssertTrue(empty.sections.isEmpty)
        let legacy = try SongTransfer.decode(Data("{\"sections\":[{\"tempoBPM\":90}]}".utf8))
        XCTAssertEqual(legacy.sections.first?.tempoBPM, 90)
    }

    @MainActor
    func testAudioFailureStopsTransportAndSuccessfulRetryClearsError() {
        enum Failure: Error { case unavailable }
        let vm = MetronomeViewModel()
        XCTAssertTrue(vm.performPlaybackStart { })
        XCTAssertTrue(vm.isPlaying)
        XCTAssertFalse(vm.performPlaybackStart { throw Failure.unavailable })
        XCTAssertFalse(vm.isPlaying)
        XCTAssertNotNil(vm.playbackError)
        XCTAssertNil(vm.displayBeat)
        XCTAssertTrue(vm.performPlaybackStart { })
        XCTAssertTrue(vm.isPlaying)
        XCTAssertNil(vm.playbackError)
        vm.stop()
    }
}
