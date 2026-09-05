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

    /// The gap-click trainer overlay (silences beats for internal-time practice). Held here, applied to
    /// the engine live; deliberately not part of `MetronomeConfiguration`, so it never affects Recents,
    /// Songs, or persisted settings. Starts disabled every launch — a practice mode you opt into.
    @Published private(set) var trainer = GapTrainer()

    /// The pickup / count-in overlay (a one-time lead-in before the first downbeat). Like `trainer`, it is
    /// a playback overlay held here — not part of `MetronomeConfiguration` — so it never touches Recents,
    /// Songs, or persistence, and it starts off every launch. Clamped to the current meter (see `Pickup`).
    @Published private(set) var pickup = Pickup.none

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
    /// Optional persisted sound preferences (selected timbre + speak-subdivisions). Injected by the app;
    /// `nil` in previews/tests, where the sound simply isn't persisted and defaults to the classic click.
    private let soundSettings: SoundSettingsStore?

    // Read-through for views.
    var bpm: Double { config.bpm }
    var timeSignature: TimeSignature { config.timeSignature }
    var subdivision: Subdivision { config.subdivision }
    var accents: [BeatAccent] { config.accents }
    var sound: MetronomeSound { config.sound }
    /// Swing / shuffle amount (0…1); 0 is straight.
    var swing: Double { config.swing }
    /// Whether swing is actually audible at the current subdivision (an eighth/sixteenth grid) rather than
    /// merely set — the Groove UI reads this so it never claims a swing that the grid renders straight.
    var swingIsAudible: Bool { config.swingIsAudible }
    /// The idiomatic sixteenth-grid cell currently applied (`.straight` = off).
    var cell: RhythmCell { config.cell }
    /// Whether the selected cell actually applies at the current subdivision (the sixteenth grid).
    var cellIsActive: Bool { config.cellIsActive }
    /// Whether Voice mode speaks the in-between subdivision syllables (persisted; default on).
    var speakSubdivisions: Bool { soundSettings?.speakSubdivisions ?? true }
    /// Voice-mode spoken volume (0…1, independent of the click volume; persisted; default 1.0).
    var voiceVolume: Double { soundSettings?.voiceVolume ?? 1.0 }

    /// Main beats (pulses) per bar of the current meter — the length of the accent pattern.
    var beatsPerBar: Int { config.beatsPerBar }
    /// The largest count-in the current meter allows: a pickup is an *incomplete* bar, so at most
    /// `beatsPerBar − 1` beats (0 for a one-beat meter, which can't have a pickup).
    var maxPickupBeats: Int { max(0, config.beatsPerBar - 1) }
    /// The count-in length, clamped to what the current meter allows (so the UI never shows a stale value
    /// larger than the meter after a meter change).
    var pickupBeats: Int { min(pickup.beats, maxPickupBeats) }
    /// Whether the count-in repeats before every bar (default false — a one-time lead-in).
    var pickupRepeats: Bool { pickup.repeatsEachCycle }

    init(config: MetronomeConfiguration = MetronomeConfiguration(),
         recents: RecentsStore? = nil,
         soundSettings: SoundSettingsStore? = nil) {
        self.recents = recents
        self.soundSettings = soundSettings
        // Restore the persisted sound preference (default classic) as the starting timbre, so the sound
        // you last chose is what you hear on launch; everything else (tempo, meter, …) starts fresh.
        var initial = config
        if let soundSettings { initial.sound = soundSettings.sound }
        self.config = initial
        engine.update(initial)
        if let soundSettings {
            engine.setSpeakSubdivisions(soundSettings.speakSubdivisions)
            engine.setVoiceVolume(soundSettings.voiceVolume)
        }
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

    /// Sets the swing / shuffle amount (0…1). Clamped by the config initializer. Delays the off-beat
    /// eighth/sixteenth pair members toward the triplet position; the main beats never move.
    ///
    /// **Self-activating:** swing only shapes the eighth/sixteenth grid, so turning it on from a grid it
    /// can't affect (quarter — the app default — triplet, or a tuplet) also advances the subdivision to
    /// eighths: enabling swing *is* a request for a swung eighth-note feel. Both writes happen in the one
    /// `updateConfig` closure, so the plan is rebuilt and published exactly once (live, if playing). Setting
    /// swing back to 0 deliberately leaves the subdivision where it is — only activation auto-advances.
    func setSwing(_ value: Double) {
        updateConfig {
            $0.swing = value
            if value > 0, $0.subdivision != .eighth, $0.subdivision != .sixteenth {
                $0.subdivision = .eighth
            }
        }
    }

    /// Selects an idiomatic rhythm cell (sixteenth grid only; `.straight` = off).
    ///
    /// **Self-activating:** a cell *is* a sixteenth-grid figure, so selecting a non-straight cell from any
    /// other grid also advances the subdivision to sixteenths — in the same single `updateConfig` publish.
    func setCell(_ cell: RhythmCell) {
        updateConfig {
            $0.cell = cell
            if cell != .straight, $0.subdivision != .sixteenth {
                $0.subdivision = .sixteenth
            }
        }
    }

    func setSound(_ sound: MetronomeSound) {
        updateConfig { $0.sound = sound }
        soundSettings?.setSound(sound)
    }

    /// Toggles whether Voice mode speaks the subdivisions aloud. Persists the preference and applies it to
    /// the engine live — it changes only whether an off-beat tick speaks a syllable or clicks, never the
    /// sample-accurate timing.
    func setSpeakSubdivisions(_ on: Bool) {
        soundSettings?.setSpeakSubdivisions(on)
        engine.setSpeakSubdivisions(on)
    }

    /// Sets the voice-mode spoken volume (0…1), independent of the click volume. Persists the preference
    /// and applies it to the engine live — it scales only the spoken numbers/syllables, never the clicks
    /// or the sample-accurate timing.
    func setVoiceVolume(_ volume: Double) {
        soundSettings?.setVoiceVolume(volume)
        engine.setVoiceVolume(volume)
    }

    // MARK: - Pickup / count-in

    /// Sets the count-in length (number of pickup beats), clamped to `0…beatsPerBar−1` for the current
    /// meter, and applies it to the engine so the next Start replays the lead-in. See `Pickup`.
    func setPickupBeats(_ beats: Int) {
        let clamped = min(max(0, beats), maxPickupBeats)
        pickup = Pickup(beats: clamped, repeatsEachCycle: pickup.repeatsEachCycle)
        engine.setPickup(pickup)
    }

    /// Toggles whether the count-in repeats before every bar (default off — a one-time lead-in).
    func setPickupRepeats(_ on: Bool) {
        pickup = Pickup(beats: pickup.beats, repeatsEachCycle: on)
        engine.setPickup(pickup)
    }

    /// Re-clamps the count-in to the current meter after a meter change (e.g. 4/4 pickup of 3 → 2/4 caps
    /// it at 1), and republishes it. A no-op when it already fits.
    private func clampPickupToMeter() {
        let clamped = min(pickup.beats, maxPickupBeats)
        guard clamped != pickup.beats else { return }
        pickup = Pickup(beats: clamped, repeatsEachCycle: pickup.repeatsEachCycle)
        engine.setPickup(pickup)
    }

    /// Loads a saved recent: applies its full configuration (restoring its BPM) and re-registers it so
    /// it surfaces to the top of Recents. Playback state is unchanged.
    func load(_ configuration: MetronomeConfiguration) {
        config = configuration
        engine.update(configuration)
        recents?.remember(configuration)
    }

    func setNumerator(_ numerator: Int) {
        updateConfig { config in
            let ts = TimeSignature(numerator: numerator, denominator: config.timeSignature.denominator)
            Self.applyMeter(ts, to: &config)
        }
        clampPickupToMeter()   // a shorter bar may no longer fit the count-in
    }

    func setDenominator(_ denominator: Int) {
        updateConfig { config in
            let ts = TimeSignature(numerator: config.timeSignature.numerator, denominator: denominator)
            Self.applyMeter(ts, to: &config)
        }
        clampPickupToMeter()   // simple↔compound changes beatsPerBar (e.g. 6/8 → 2 beats)
    }

    /// Applies a new meter: adopts its sensible default accents (compound-aware) and, on a simple↔compound
    /// switch, resets the subdivision to the main beat so a simple-meter subdivision isn't misread as a
    /// compound one (e.g. 4/4 eighths shouldn't carry over as 6/8 "eighths" = a triplet division).
    private static func applyMeter(_ ts: TimeSignature, to config: inout MetronomeConfiguration) {
        let compoundChanged = ts.isCompound != config.timeSignature.isCompound
        config.timeSignature = ts
        config.accents = ts.defaultAccents
        if compoundChanged { config.subdivision = .quarter }
    }

    /// Cycles beat `index` to its next accent state (strong → medium → normal → muted → strong).
    func cycleAccent(_ index: Int) {
        updateConfig {
            if $0.accents.indices.contains(index) { $0.accents[index] = $0.accents[index].next }
        }
    }

    /// Applies a beat grouping (e.g. 2+2+3) to the current meter: beat 1 becomes a strong accent, each
    /// subsequent group head a medium (secondary) accent, and every other beat normal. Used by the meter
    /// UI's quick grouping presets for asymmetric meters.
    func applyGrouping(_ groups: [Int]) {
        updateConfig {
            var pattern = [BeatAccent](repeating: .normal, count: $0.beatsPerBar)
            guard !pattern.isEmpty else { return }
            pattern[0] = .strong
            var index = 0
            for size in groups where size > 0 {
                if index > 0 && index < pattern.count { pattern[index] = .medium }
                index += size
            }
            $0.accents = pattern
        }
    }

    // MARK: - Gap-click trainer

    /// Turns the trainer on/off. Enabling random mode reseeds so each practice run is unpredictable
    /// (the seed is fixed only for reproducible tests).
    func setTrainerEnabled(_ on: Bool) {
        updateTrainer {
            $0.isEnabled = on
            if on { $0.seed = UInt64.random(in: UInt64.min...UInt64.max) }
        }
    }

    func setTrainerMode(_ mode: GapTrainer.Mode) { updateTrainer { $0.mode = mode } }
    func setTrainerMutePercent(_ percent: Int)   { updateTrainer { $0.mutePercent = percent } }
    func setTrainerBarsOn(_ bars: Int)           { updateTrainer { $0.barsOn = bars } }
    func setTrainerBarsOff(_ bars: Int)          { updateTrainer { $0.barsOff = bars } }
    func setTrainerKeepDownbeat(_ on: Bool)      { updateTrainer { $0.keepDownbeat = on } }
    func setTrainerRampEnabled(_ on: Bool)       { updateTrainer { $0.rampEnabled = on } }
    func setTrainerRampBars(_ bars: Int)         { updateTrainer { $0.rampBars = bars } }
    func setTrainerRampMutePercentPeak(_ p: Int) { updateTrainer { $0.rampMutePercentPeak = p } }
    func setTrainerRampBarsOffPeak(_ bars: Int)  { updateTrainer { $0.rampBarsOffPeak = bars } }

    /// Draws a fresh random pattern without toggling anything else (a "reshuffle").
    func reshuffleTrainer() { updateTrainer { $0.seed = UInt64.random(in: UInt64.min...UInt64.max) } }

    private func updateTrainer(_ mutate: (inout GapTrainer) -> Void) {
        var next = trainer
        mutate(&next)
        next = next.normalized()
        trainer = next
        engine.setTrainer(next)
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
                                                sound: next.sound,
                                                swing: next.swing,
                                                cell: next.cell)
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
        BeatVisualState(beatsPerMeasure: config.beatsPerBar,
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
