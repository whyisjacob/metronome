import SwiftUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Bridges the pure `MetronomeEngine` to SwiftUI. Owns the user-facing configuration, transport
/// state, and the visual beat indicator. It contains no click-timing logic — that lives entirely in
/// the engine — so this layer can be replaced (e.g. by a Watch UI) without touching accuracy.
@MainActor
final class MetronomeViewModel: ObservableObject {

    @Published private(set) var config: MetronomeConfiguration
    @Published private(set) var isPlaying = false

    // Visual beat indicator, refreshed by `pollPulse()` which the view drives at display rate.
    @Published private(set) var activeBeat: Int?
    @Published private(set) var activeAccent: AccentLevel = .normal
    /// Bumps once per click; views key transient flash animations off this.
    @Published private(set) var flashID: UInt64 = 0

    private let engine = MetronomeEngine()
    private var tapTempo = TapTempo()
    private var lastPulseSequence: UInt64 = 0

    // Read-through for views.
    var bpm: Double { config.bpm }
    var timeSignature: TimeSignature { config.timeSignature }
    var subdivision: Subdivision { config.subdivision }
    var accents: [Bool] { config.accents }

    init(config: MetronomeConfiguration = MetronomeConfiguration()) {
        self.config = config
        engine.update(config)
        engine.onPlaybackStateChanged = { [weak self] playing in
            // Delivered on the main queue by the engine.
            self?.reconcilePlaybackState(playing)
        }
    }

    // MARK: - Transport

    func toggle() { isPlaying ? stop() : start() }

    func start() {
        do {
            try engine.start()
        } catch {
            return   // v1 stays silent on failure; surfacing audio errors is future work.
        }
        setPlaying(true)
    }

    func stop() {
        engine.stop()
        setPlaying(false)
    }

    /// Called when the engine changes playback state on its own (interruption ended, headphones
    /// unplugged, media services reset). Idempotent against user-initiated changes.
    private func reconcilePlaybackState(_ playing: Bool) {
        guard playing != isPlaying else { return }
        setPlaying(playing)
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if !playing {
            activeBeat = nil
            lastPulseSequence = 0
        }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = playing   // keep the screen awake while playing
        #endif
    }

    // MARK: - Configuration edits

    func setBPM(_ value: Double) { updateConfig { $0.bpm = value } }

    func nudgeBPM(_ delta: Double) { setBPM((config.bpm + delta).rounded()) }

    func setSubdivision(_ subdivision: Subdivision) { updateConfig { $0.subdivision = subdivision } }

    func setNumerator(_ numerator: Int) {
        updateConfig {
            $0.timeSignature = TimeSignature(numerator: numerator,
                                             denominator: $0.timeSignature.denominator)
        }
    }

    func setDenominator(_ denominator: Int) {
        updateConfig {
            $0.timeSignature = TimeSignature(numerator: $0.timeSignature.numerator,
                                             denominator: denominator)
        }
    }

    func toggleAccent(_ index: Int) {
        updateConfig {
            if $0.accents.indices.contains(index) { $0.accents[index].toggle() }
        }
    }

    /// Registers a tap-tempo tap using a monotonic clock and applies the resulting BPM.
    func tap() {
        if let detected = tapTempo.addTap(at: CACurrentMediaTime()) {
            setBPM(detected.rounded())
        }
    }

    /// Mutates a copy of the config, re-normalizes invariants via the initializer (bpm clamp,
    /// accent-array length), publishes it, and hands it to the engine.
    private func updateConfig(_ mutate: (inout MetronomeConfiguration) -> Void) {
        var next = config
        mutate(&next)
        let normalized = MetronomeConfiguration(bpm: next.bpm,
                                                timeSignature: next.timeSignature,
                                                subdivision: next.subdivision,
                                                accents: next.accents)
        config = normalized
        engine.update(normalized)
    }

    // MARK: - Visual polling (called by the view at display rate)

    /// Reflects the engine's latest emitted click into the published indicator state. Cheap and
    /// idempotent; safe to call every frame. Never used for click *timing* — that is sample-accurate
    /// in the engine — only to refresh the on-screen pulse.
    func pollPulse() {
        guard isPlaying else { return }
        let pulse = engine.currentPulse
        guard pulse.sequence != lastPulseSequence else { return }
        lastPulseSequence = pulse.sequence
        activeBeat = pulse.beatIndex
        activeAccent = pulse.accent
        flashID = pulse.sequence
    }
}
