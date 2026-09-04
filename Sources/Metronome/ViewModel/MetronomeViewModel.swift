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
    /// Current beat (0-based) held *sticky* across the subdivision clicks between beats — unlike
    /// `activeBeat`, which goes `nil` on a subdivision click. Feeds the counter/ring/dots indicators.
    @Published private(set) var displayBeat: Int?
    /// 0 on the beat, then 1…ticksPerBeat-1 through the subdivisions of the current beat.
    @Published private(set) var subdivisionPhase = 0
    /// Whether the latest click landed on a beat (vs a subdivision between beats).
    @Published private(set) var isOnBeat = false

    private let engine = MetronomeEngine()
    private var tapTempo = TapTempo()
    private var lastPulseSequence: UInt64 = 0
    /// Optional Recents store: every committed configuration change is registered here.
    private let recents: RecentsStore?

    // Read-through for views.
    var bpm: Double { config.bpm }
    var timeSignature: TimeSignature { config.timeSignature }
    var subdivision: Subdivision { config.subdivision }
    var accents: [Bool] { config.accents }
    var sound: MetronomeSound { config.sound }

    init(config: MetronomeConfiguration = MetronomeConfiguration(),
         recents: RecentsStore? = nil) {
        self.config = config
        self.recents = recents
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
        recents?.remember(config)   // the config you actually played becomes/refreshes a recent
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
            displayBeat = nil
            subdivisionPhase = 0
            isOnBeat = false
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

    func setSound(_ sound: MetronomeSound) { updateConfig { $0.sound = sound } }

    /// Loads a saved recent: applies its full configuration (restoring its BPM) and re-registers it so
    /// it surfaces to the top of Recents. Playback state is unchanged.
    func load(_ configuration: MetronomeConfiguration) {
        config = configuration
        engine.update(configuration)
        recents?.remember(configuration)
    }

    func setNumerator(_ numerator: Int) {
        updateConfig {
            let ts = TimeSignature(numerator: numerator, denominator: $0.timeSignature.denominator)
            $0.timeSignature = ts
            $0.accents = ts.defaultAccents   // adopt the new meter's sensible pattern (compound-aware)
        }
    }

    func setDenominator(_ denominator: Int) {
        updateConfig {
            let ts = TimeSignature(numerator: $0.timeSignature.numerator, denominator: denominator)
            $0.timeSignature = ts
            $0.accents = ts.defaultAccents   // e.g. 6/4 → 6/8 switches to dotted-quarter group accents
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
                                                accents: next.accents,
                                                sound: next.sound)
        config = normalized
        engine.update(normalized)
        recents?.remember(normalized)
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
        let wasBeat = pulse.beatIndex != nil
        isOnBeat = wasBeat
        if let beat = pulse.beatIndex { displayBeat = beat }   // sticky: hold the beat through its subdivisions
        subdivisionPhase = BeatVisualState.nextSubdivisionPhase(previous: subdivisionPhase,
                                                                wasBeat: wasBeat,
                                                                ticksPerBeat: config.ticksPerBeat)
    }

    /// The immutable snapshot the selected beat indicator renders from — built from the polled pulse and
    /// the current configuration, so every indicator style stays synced to the audio.
    var visualState: BeatVisualState {
        BeatVisualState(beatsPerMeasure: timeSignature.numerator,
                        ticksPerBeat: config.ticksPerBeat,
                        accents: accents,
                        currentBeat: isPlaying ? displayBeat : nil,
                        subdivisionPhase: subdivisionPhase,
                        accentLevel: activeAccent,
                        flashID: flashID,
                        isPlaying: isPlaying,
                        isOnBeat: isOnBeat)
    }
}
