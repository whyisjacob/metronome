import SwiftUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Drives song playback for the Play screen: owns a `MetronomeEngine` in song mode and mirrors the
/// engine's truth (current section, current bar, end-of-song) into published state. Contains no
/// click-timing logic — sounding is sample-accurate in the engine; this only reflects it for the UI,
/// exactly like `MetronomeViewModel` does for the single-tempo screen.
@MainActor
final class SongPlayerViewModel: ObservableObject {

    let song: Song

    @Published private(set) var isPlaying = false
    /// Index of the section currently sounding, or `nil` before start / after finish.
    @Published private(set) var currentSectionIndex: Int?
    /// 1-based bar within the current section.
    @Published private(set) var currentBar: Int = 0
    @Published private(set) var activeBeat: Int?
    @Published private(set) var activeAccent: AccentLevel = .normal
    @Published private(set) var flashID: UInt64 = 0
    @Published private(set) var didFinish = false

    private let engine = MetronomeEngine()
    private var lastSequence: UInt64 = 0

    init(song: Song) {
        self.song = song
        engine.onPlaybackStateChanged = { [weak self] playing in
            self?.reconcilePlaybackState(playing)
        }
    }

    // MARK: - Transport

    func toggle() { isPlaying ? stop() : start() }

    func start() {
        guard !song.sections.isEmpty else { return }
        didFinish = false
        currentSectionIndex = nil
        do {
            try engine.startSong(song)
        } catch {
            return   // v2 stays silent on failure, matching the single-tempo screen.
        }
        setPlaying(true)
    }

    func stop() {
        engine.stop()
        setPlaying(false)
    }

    private func reconcilePlaybackState(_ playing: Bool) {
        guard playing != isPlaying else { return }
        setPlaying(playing)
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if !playing {
            activeBeat = nil
            lastSequence = 0
        }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = playing
        #endif
    }

    // MARK: - Visual polling (display rate; cosmetic only)

    func poll() {
        guard isPlaying else { return }
        let pulse = engine.currentPulse
        guard pulse.sequence != lastSequence else { return }
        lastSequence = pulse.sequence

        if pulse.songFinished {
            didFinish = true
            stop()
            currentSectionIndex = nil
            return
        }
        currentSectionIndex = pulse.sectionIndex
        currentBar = (pulse.barInSection ?? 0) + 1
        activeBeat = pulse.beatIndex
        activeAccent = pulse.accent
        flashID = pulse.sequence
    }

    // MARK: - Derived UI state

    var currentSection: SongSection? {
        guard let i = currentSectionIndex, song.sections.indices.contains(i) else { return nil }
        return song.sections[i]
    }

    var nextSection: SongSection? {
        guard let i = currentSectionIndex, song.sections.indices.contains(i + 1) else { return nil }
        return song.sections[i + 1]
    }
}
