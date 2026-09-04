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
    /// Current beat (0-based) held sticky across subdivisions; drives the selected beat indicator.
    @Published private(set) var displayBeat: Int?
    /// 0 on the beat, then 1…ticksPerBeat-1 through the current beat's subdivisions.
    @Published private(set) var subdivisionPhase = 0
    /// Whether the latest click landed on a beat (vs a subdivision between beats).
    @Published private(set) var isOnBeat = false

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
            displayBeat = nil
            subdivisionPhase = 0
            isOnBeat = false
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
        let wasBeat = pulse.beatIndex != nil
        isOnBeat = wasBeat
        if let beat = pulse.beatIndex { displayBeat = beat }
        // `currentSection` already reflects the pulse we just applied above.
        let ticksPerBeat = currentSection?.ticksPerBeat ?? 1
        subdivisionPhase = BeatVisualState.nextSubdivisionPhase(previous: subdivisionPhase,
                                                                wasBeat: wasBeat,
                                                                ticksPerBeat: ticksPerBeat)
    }

    /// The snapshot the selected beat indicator renders from, built from the current section's meter /
    /// subdivision / accents and the polled pulse. `nil`-safe: idle before the first click.
    var visualState: BeatVisualState {
        guard isPlaying, let section = currentSection else { return BeatVisualState.idle() }
        return BeatVisualState(beatsPerMeasure: section.beatsPerBar,
                               ticksPerBeat: section.ticksPerBeat,
                               accents: section.accentPattern,
                               currentBeat: displayBeat,
                               subdivisionPhase: subdivisionPhase,
                               accentLevel: activeAccent,
                               flashID: flashID,
                               isPlaying: true,
                               isOnBeat: isOnBeat)
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
