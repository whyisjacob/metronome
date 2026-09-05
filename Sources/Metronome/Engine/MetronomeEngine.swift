import AVFoundation
import os

/// The accuracy core. UI-independent and reusable (a future Watch app can drive it unchanged).
///
/// ## Scheduling approach — `AVAudioSourceNode` render callback
/// Of the two sanctioned sample-accurate options, this uses an **`AVAudioSourceNode`** whose render
/// block writes click samples at exact frame offsets, rather than `AVAudioPlayerNode.scheduleBuffer`.
/// Rationale:
///  - Onsets are placed at exactly `round(N × secondsPerTick × sampleRate)` *by our own code*, with
///    no dependence on scheduling granularity, completion handlers, or player-node buffer queueing.
///  - The identical code path runs under AVAudioEngine **offline manual-rendering**, so the headless
///    accuracy test verifies the real render path (not a stand-in) to the sample.
///  - It is trivially reusable and has no per-tick scheduling/allocation churn.
///
/// ## Threading
/// The audio render thread is the source of truth for *when* a click sounds. The render block reads
/// an immutable `RenderPlan` published under a tiny `OSAllocatedUnfairLock` critical section (a
/// pointer + two bools), and mutates only `AudioThreadState`, which nothing else touches. Parameter
/// changes are user-paced and therefore rare relative to the audio callback. This is the pragmatic,
/// well-documented tradeoff; a fully lock-free triple-buffered publish (via the Swift `Synchronization`
/// framework) is the upgrade path once the deployment target reaches iOS 18.
///
/// > NONE of this has been compiled or run — it is authored on Windows. See README/report.
final class MetronomeEngine {

    enum EngineError: Error {
        case bufferAllocationFailed
        case sourceNodeUnavailable
    }

    // MARK: Published-to-main callbacks (invoked on the main queue)

    /// Called whenever playback starts/stops, including auto-changes from interruptions/route loss,
    /// so the UI can stay the mirror of the engine's truth.
    var onPlaybackStateChanged: ((Bool) -> Void)?

    // MARK: AVFoundation

    private let avEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let session = AudioSessionController()

    private(set) var configuredSampleRate: Double = 0
    private var isManualRendering = false
    private var sessionWired = false

    // MARK: Shared state (main <-> audio thread)

    private struct Control {
        var plan: RenderPlan?
        /// Non-nil ⇒ song mode: the render callback walks this pre-expanded click stream instead of
        /// the single-tempo `plan`. Exactly one of the two is active at a time.
        var songPlan: SongPlan?
        var running = false
        var resetRequested = false
        /// Sound buffers, published under this lock so a live sound change is race-free. All three are
        /// `[[Float]]` (indexed by accent level, or by beat for `voiceTable`) — COW value types, so the
        /// audio thread snapshots them with a cheap retain, never an allocation.
        var clickTable: [[Float]] = []      // the selected click timbre (single-tempo mode)
        var pickupTable: [[Float]] = []     // the selected timbre, pitch-shifted — the distinct pickup tone
        var voiceTable: [[Float]] = []      // spoken numbers, indexed by beat (0 == "one"); may be empty
        var voiceSyllableTable: [[Float]] = [] // spoken subdivision syllables, indexed by VoiceSyllable.rawValue
        var classicTable: [[Float]] = []    // always the classic click — song mode & fallback
        /// Single-tempo Voice mode: speak the beat number instead of clicking on beats.
        var voiceMode = false
        /// User preference: in Voice mode also speak the in-between subdivision syllables ("1 e and a").
        /// When off — or at a tempo too fast to articulate them — the subdivisions click instead, so the
        /// beat numbers still speak cleanly. Default on. Read live by the render callback; never affects
        /// onset timing.
        var speakSubdivisions = true
        /// Voice-mode gain applied to SPOKEN tokens (numbers + syllables) only, independent of the click
        /// volume. Clicks are never scaled, so the accuracy-critical click path is unchanged. Default 1.0.
        var voiceVolume: Double = 1.0
        /// Sample rate `voiceTable` was rendered at (0 = none) and the rate currently rendering in the
        /// background (0 = idle). Guard the lazy voice render so it publishes/re-renders exactly once.
        var voiceRate: Double = 0
        var voiceRenderingRate: Double = 0
    }
    private let control = OSAllocatedUnfairLock(initialState: Control())

    /// The most recent click the audio thread emitted, for the visual beat indicator. The UI polls
    /// this (e.g. via a display link / timer) and reacts when `sequence` advances.
    ///
    /// The `section*` / `songFinished` fields are populated only in song mode (nil / false otherwise),
    /// so the UI can show the current section, the current bar, and stop cleanly at the end.
    struct BeatPulse: Equatable {
        var sequence: UInt64 = 0
        var tickIndex: Int = -1
        var beatIndex: Int?
        var accent: AccentLevel = .normal
        /// Index of the section the latest click belongs to (song mode only).
        var sectionIndex: Int?
        /// 0-based bar within that section for the latest click (song mode only).
        var barInSection: Int?
        /// Set once when the song's final click has sounded and playback has reached the song's end.
        var songFinished: Bool = false
    }
    private let pulse = OSAllocatedUnfairLock(initialState: BeatPulse())

    /// Reads the latest beat pulse (main thread).
    var currentPulse: BeatPulse { pulse.withLock { $0 } }

    // MARK: Audio-thread-only state

    private struct Voice {
        var bufferIndex = 0
        var playhead = 0
        var active = false
        /// Which buffer table this voice reads from: 0 = selected click timbre, 1 = spoken number,
        /// 2 = classic click (song mode / fallback). A voice keeps its table across render blocks.
        var table = 0
        /// Linear release: <0 = play at full gain; ≥0 = frames of fade-out still to apply before the
        /// voice is cut. Used to fade the previous spoken number when the next one starts, so numbers
        /// don't slur or pile up at fast tempo.
        var fadeRemaining = -1
    }
    private final class AudioThreadState {
        var framesElapsed = 0
        /// Single-tempo cursor: the next tick to schedule, counted **relative to `epochFrame`** (not
        /// from playback start). A live config swap re-anchors `epochFrame`/`nextTick` so the running
        /// schedule continues seamlessly — see `anchorPlanSwap(to:blockStart:)`.
        var nextTick = 0
        /// Absolute frame (from playback start) at which the current single-tempo plan's tick 0 sits.
        /// Onset of tick `t` == `epochFrame + plan.frame(forTick: t)`. Zero at playback start; shifted
        /// (by a whole-sample constant, so drift-free) whenever the live plan is swapped mid-playback.
        var epochFrame = 0
        /// Song-mode cursor: the index of the next click to consider in `SongPlan`.
        var nextClickIndex = 0
        /// One-shot guard so the end-of-song pulse is published exactly once.
        var songFinishedPublished = false
        var voices = [Voice](repeating: Voice(), count: 16)
    }
    private let atState = AudioThreadState()

    // Audio-thread-only working snapshots of the published sound buffers, refreshed at the top of every
    // render block (a cheap COW retain). Only `render`/`mix` touch these, so there is no race.
    private var atSelectedTable: [[Float]] = []
    private var atPickupTable: [[Float]] = []
    private var atVoiceTable: [[Float]] = []
    private var atVoiceSyllableTable: [[Float]] = []
    private var atClassicTable: [[Float]] = []
    private var atVoiceMode = false
    private var atSpeakSubdivisions = true
    /// Audio-thread snapshot of the spoken-voice gain (see `Control.voiceVolume`). Applied in `mix` to
    /// spoken tables only; 1.0 for clicks, so the click path is byte-for-byte unchanged.
    private var atVoiceVolume: Double = 1.0
    /// The single-tempo plan the audio thread is currently scheduling from. Compared by identity against
    /// the published plan each block to detect a live swap (a new `RenderPlan` from `update(_:)`); `nil`
    /// after a reset so the first plan anchors cleanly. Audio-thread-only, so no synchronization needed.
    private var atPlan: RenderPlan?
    /// Length of the spoken-number release fade, in frames (set per sample rate). Read on the audio
    /// thread; written once in `installSourceNode` before audio flows.
    private var voiceReleaseFrames = 256
    /// Declick length (frames) for the hard cut applied to a still-sounding spoken token at the next
    /// spoken onset, so successive counts never overlap. A couple of milliseconds — short enough to read
    /// as an immediate stop, long enough not to click. Set per sample rate in `installSourceNode`.
    private var voiceHardCutFrames = 64

    // MARK: Voice pre-rendering (main-thread bookkeeping + a background render queue)

    /// The click sound whose table is currently published, so `applySound` rebuilds only on a change.
    private var installedClickSound: MetronomeSound?
    private let voiceRenderQueue = DispatchQueue(label: "app.metronome.voice-render", qos: .userInitiated)

    // MARK: Current configuration (main thread)

    private(set) var currentConfig = MetronomeConfiguration()
    /// The gap-click trainer overlay applied to single-tempo playback (never to songs). Held here so a
    /// live toggle republishes the plan seamlessly; captured into every `RenderPlan` this engine builds.
    private(set) var currentTrainer = GapTrainer()
    /// The pickup / count-in overlay applied to single-tempo playback (never to songs). Held here and
    /// captured into every single-tempo `RenderPlan`, so pressing Start replays the lead-in from tick 0.
    private(set) var currentPickup = Pickup.none
    /// The song most recently handed to `startSong(_:)`, for reference by the UI/view model.
    private(set) var currentSong: Song?
    /// Which mode the last `start*` selected, so an interruption/route recovery resumes the right one.
    private var songModeActive = false
    private(set) var isRunning = false

    // MARK: - Configuration

    /// Applies a new configuration, publishing a fresh `RenderPlan` to the audio thread. Timing takes
    /// effect at the next tick boundary; the click-buffer table is untouched (same sample rate).
    func update(_ config: MetronomeConfiguration) {
        currentConfig = config
        guard configuredSampleRate > 0 else { return }
        let plan = RenderPlan(config: config, sampleRate: configuredSampleRate,
                              trainer: currentTrainer, pickup: currentPickup)
        control.withLock { $0.plan = plan }
        applySound(config.sound)
    }

    // MARK: - Gap-click trainer

    /// Applies a new trainer overlay. Takes effect live: it republishes the single-tempo plan with the
    /// new trainer captured, so beats start/stop being silenced immediately, with no timing disruption
    /// (the swap is phase-compatible — same meter and subdivision — so the running grid is preserved).
    /// Song mode is intentionally untouched; the trainer applies to single-tempo practice only.
    func setTrainer(_ trainer: GapTrainer) {
        currentTrainer = trainer
        guard configuredSampleRate > 0 else { return }
        let plan = RenderPlan(config: currentConfig, sampleRate: configuredSampleRate,
                              trainer: trainer, pickup: currentPickup)
        control.withLock { if $0.songPlan == nil { $0.plan = plan } }
    }

    // MARK: - Pickup / count-in

    /// Applies a new pickup / count-in overlay. Republishes the single-tempo plan (never a song) so the
    /// count-in takes effect on the next Start (playback replays from tick 0); it is phase-compatible
    /// (same meter/subdivision) so a live change never disrupts a running grid. See `Pickup`.
    func setPickup(_ pickup: Pickup) {
        currentPickup = pickup
        guard configuredSampleRate > 0 else { return }
        let plan = RenderPlan(config: currentConfig, sampleRate: configuredSampleRate,
                              trainer: currentTrainer, pickup: pickup)
        control.withLock { if $0.songPlan == nil { $0.plan = plan } }
    }

    /// Sets the voice-mode gain applied to SPOKEN tokens (numbers + subdivision syllables), independent of
    /// the click volume. Read live by the render callback (no plan rebuild, no timing change); clicks are
    /// never scaled, so the sample-accurate click path is byte-for-byte unchanged. Default 1.0.
    func setVoiceVolume(_ volume: Double) {
        control.withLock { $0.voiceVolume = max(0, min(1, volume)) }
    }

    // MARK: - Sound selection

    /// Publishes the buffers for `sound`: the click-timbre table used in single-tempo mode and, for
    /// `.voice`, the lazy spoken-number render. Cheap unless the click timbre actually changed, and it
    /// never blocks — voice buffers render on a background queue and publish when ready (until then Voice
    /// mode falls back to clicks). Needs a known sample rate, so it runs from `start()` (after the
    /// session is up) and from `update(_:)` while playing.
    private func applySound(_ sound: MetronomeSound) {
        guard configuredSampleRate > 0 else {
            control.withLock { $0.voiceMode = sound.isVoice }
            return
        }
        // Voice reuses the classic click for its subdivision ticks and as its pre-render fallback.
        let clickSound: MetronomeSound = sound.isVoice ? .classic : sound
        if installedClickSound != clickSound {
            let table = ClickSoundFactory.makeClickTable(sampleRate: configuredSampleRate, sound: clickSound)
            let pickupTable = ClickSoundFactory.makePickupTable(sampleRate: configuredSampleRate, sound: clickSound)
            control.withLock { $0.clickTable = table; $0.pickupTable = pickupTable }
            installedClickSound = clickSound
        }
        control.withLock { $0.voiceMode = sound.isVoice }
        if sound.isVoice { ensureVoiceRendered() }
    }

    /// Renders the spoken-number buffers once for the current sample rate on a background queue and
    /// publishes them. Guarded through the control lock so it renders at most once per rate and a stale
    /// render (after a rate change) is dropped rather than published over the current one.
    private func ensureVoiceRendered() {
        let sr = configuredSampleRate
        guard sr > 0 else { return }
        let shouldRender: Bool = control.withLock { c in
            if c.voiceRate == sr || c.voiceRenderingRate == sr { return false }  // have it / rendering it
            c.voiceRenderingRate = sr                                            // claim this rate
            return true
        }
        guard shouldRender else { return }

        let maxNumber = TimeSignature.numeratorRange.upperBound
        voiceRenderQueue.async { [weak self] in
            let numbers = VoiceSampleFactory.renderSpokenNumbers(upTo: maxNumber, sampleRate: sr)
            let syllables = VoiceSampleFactory.renderSyllables(sampleRate: sr)
            guard let self else { return }
            self.control.withLock { c in
                guard c.voiceRenderingRate == sr else { return }   // superseded by a rate change → drop
                c.voiceRenderingRate = 0
                // Publish only if the numbers rendered. Syllables may be empty (a headless environment,
                // or a partial synth failure); the engine then simply clicks the subdivision ticks.
                if !numbers.isEmpty {
                    c.voiceTable = numbers
                    c.voiceSyllableTable = syllables
                    c.voiceRate = sr
                }
            }
        }
    }

    /// Sets whether Voice mode speaks the in-between subdivision syllables. Read live by the render
    /// callback (no plan rebuild, no timing change): it only decides whether an off-beat tick speaks a
    /// syllable or clicks. Default on.
    func setSpeakSubdivisions(_ on: Bool) {
        control.withLock { $0.speakSubdivisions = on }
    }

    /// Test-only seam: publish synthetic spoken-number / syllable buffers so a headless test can exercise
    /// the REAL Voice render path — the hard-cut between successive counts and the fast-tempo degrade —
    /// without the app's bundled `.wav` resources, which a logic-test bundle does not carry (there the
    /// loader returns `[]` and the engine clicks, so the spoken schedule would otherwise never run in CI).
    /// Marks the rate as already rendered so the lazy background render is a no-op and cannot clobber the
    /// injected tables. Not called by the app.
    func installSyntheticVoiceTablesForTesting(numbers: [[Float]],
                                               syllables: [[Float]],
                                               sampleRate: Double) {
        control.withLock {
            $0.voiceTable = numbers
            $0.voiceSyllableTable = syllables
            $0.voiceRate = sampleRate
            $0.voiceRenderingRate = 0
        }
    }

    // MARK: - Real-time transport

    /// Starts (or restarts) the single-tempo click from tick 0. Clears any song plan so the two modes
    /// never both drive the callback.
    func start() throws {
        guard !isManualRendering else { return }
        try ensureRealtimeEngineRunning()
        applySound(currentConfig.sound)     // (re)build the selected timbre / voice at the live rate
        let plan = RenderPlan(config: currentConfig, sampleRate: configuredSampleRate,
                              trainer: currentTrainer, pickup: currentPickup)
        songModeActive = false
        control.withLock {
            $0.plan = plan
            $0.songPlan = nil
            $0.running = true
            $0.resetRequested = true
        }
        setRunning(true)
    }

    /// Starts a whole song from its first click. The tempo-map is expanded once into a `SongPlan`
    /// (sample-accurate, zero drift across boundaries) and published to the *same* render callback
    /// `start()` uses — song mode adds no timer/`asyncAfter` sounding, only a different onset source.
    func startSong(_ song: Song) throws {
        guard !isManualRendering else { return }
        currentSong = song
        try ensureRealtimeEngineRunning()
        let plan = SongPlan(song: song, sampleRate: configuredSampleRate)
        songModeActive = true
        control.withLock {
            $0.songPlan = plan
            $0.plan = nil
            $0.running = true
            $0.resetRequested = true
        }
        setRunning(true)
    }

    /// Restarts whichever mode was last active — used by interruption/route recovery so a song resumes
    /// as a song (from its start) rather than silently reverting to the single-tempo click.
    private func restartCurrent() throws {
        if songModeActive, let song = currentSong {
            try startSong(song)
        } else {
            try start()
        }
    }

    func stop() {
        control.withLock { $0.running = false }
        avEngine.pause()
        setRunning(false)
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        let cb = onPlaybackStateChanged
        DispatchQueue.main.async { cb?(running) }
    }

    private func ensureRealtimeEngineRunning() throws {
        try session.activate()                 // idempotent; re-activates after interruptions
        if !sessionWired { wireSessionCallbacks(); sessionWired = true }

        let sr = session.sampleRate
        if sourceNode == nil || configuredSampleRate != sr {
            installSourceNode(sampleRate: sr)
        }
        if !avEngine.isRunning {
            avEngine.prepare()
            try avEngine.start()
        }
    }

    private func wireSessionCallbacks() {
        session.onInterruptionBegan = { [weak self] in
            self?.avEngine.pause()
        }
        session.onInterruptionEnded = { [weak self] shouldResume in
            guard let self, self.isRunning, shouldResume else { return }
            try? self.restartCurrent()         // rebuild session/engine and restart cleanly
        }
        session.onRouteChange = { [weak self] reason in
            guard let self else { return }
            switch reason {
            case .oldDeviceUnavailable:
                // e.g. headphones unplugged — pause rather than surprise the room via the speaker.
                if self.isRunning { self.stop() }
            case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange:
                if self.isRunning, self.session.sampleRate != self.configuredSampleRate {
                    try? self.restartCurrent() // sample rate changed: rebuild at the new rate
                }
            default:
                break
            }
        }
        session.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            // The media server died and restarted: everything must be rebuilt.
            self.sourceNode = nil
            self.configuredSampleRate = 0
            if self.isRunning { try? self.restartCurrent() }
        }
    }

    private func installSourceNode(sampleRate: Double) {
        if let existing = sourceNode {
            avEngine.detach(existing)
            sourceNode = nil
        }
        configuredSampleRate = sampleRate
        voiceReleaseFrames = max(Int(0.005 * sampleRate), 32)
        voiceHardCutFrames = max(Int(0.0015 * sampleRate), 24)

        // Rebuild the classic click at this rate and publish it as both the default single-tempo table
        // and the song-mode/fallback table. `applySound` (from start/update) then overlays the selected
        // timbre or voice. A fresh engine — including the offline accuracy tests — therefore renders the
        // classic click with no dependence on the sound-selection system.
        let classic = ClickSoundFactory.makeClickTable(sampleRate: sampleRate, sound: .classic)
        let classicPickup = ClickSoundFactory.makePickupTable(sampleRate: sampleRate, sound: .classic)
        installedClickSound = nil
        control.withLock {
            $0.classicTable = classic
            $0.clickTable = classic
            $0.pickupTable = classicPickup
            $0.voiceTable = []
            $0.voiceSyllableTable = []
            $0.voiceMode = false
            $0.voiceRate = 0
            $0.voiceRenderingRate = 0
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl in
            guard let self else {
                Self.silence(abl)
                return noErr
            }
            return self.render(frameCount: frameCount, into: abl)
        }
        sourceNode = node
        avEngine.attach(node)
        // Connect straight to the output node — no mixer in the path — so nothing can shift or
        // ramp a sample. In offline manual-rendering the output format equals `format`, so there is
        // no sample-rate conversion and onsets stay bit-exact.
        avEngine.connect(node, to: avEngine.outputNode, format: format)
    }

    // MARK: - Offline rendering (deterministic; used by the accuracy tests)

    /// Configures the engine for AVAudioEngine offline manual rendering at `sampleRate`.
    func prepareForOfflineRendering(sampleRate: Double,
                                    maximumFrameCount: AVAudioFrameCount = 4096) throws {
        installSourceNode(sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw EngineError.sourceNodeUnavailable
        }
        try avEngine.enableManualRenderingMode(.offline, format: format,
                                               maximumFrameCount: maximumFrameCount)
        avEngine.prepare()
        try avEngine.start()
        isManualRendering = true
    }

    /// Renders `seconds` of the single-tempo click offline and returns channel-0 float samples. The
    /// returned array's index is the absolute frame from playback start, so onsets can be measured
    /// directly.
    func renderOffline(config: MetronomeConfiguration, seconds: Double) throws -> [Float] {
        update(config)
        control.withLock {
            $0.plan = RenderPlan(config: config, sampleRate: configuredSampleRate,
                                 trainer: currentTrainer, pickup: currentPickup)
            $0.songPlan = nil
            $0.running = true
            $0.resetRequested = true
        }
        let totalFrames = Int((seconds * configuredSampleRate).rounded())
        return try drainOfflineRender(totalFrames: totalFrames)
    }

    /// Renders a whole `song` offline through the real song-mode render path and returns channel-0
    /// float samples (index == absolute frame). Renders the song's exact integer length plus a short
    /// tail so the final click's body is fully captured; no click exists at or after `totalFrames`,
    /// so the tail cannot introduce a spurious onset.
    func renderOfflineSong(_ song: Song) throws -> [Float] {
        let plan = SongPlan(song: song, sampleRate: configuredSampleRate)
        control.withLock {
            $0.songPlan = plan
            $0.plan = nil
            $0.running = true
            $0.resetRequested = true
        }
        let tail = Int((0.05 * configuredSampleRate).rounded())
        return try drainOfflineRender(totalFrames: plan.totalFrames + tail)
    }

    /// Renders the single-tempo click offline while switching from `first` to `second` partway through —
    /// the deterministic analogue of changing settings (dragging the BPM slider, changing meter or
    /// subdivision) mid-playback. It drives the **same live `update(_:)` path and render callback** the
    /// UI uses, so what it verifies is the real live re-anchor, not a stand-in. Returns channel-0 samples
    /// (index == absolute frame from playback start) and the frame at which `second` was published.
    func renderOfflineChanging(from first: MetronomeConfiguration,
                               to second: MetronomeConfiguration,
                               changeAtSeconds: Double,
                               totalSeconds: Double) throws -> (samples: [Float], changeFrame: Int) {
        update(first)
        control.withLock {
            $0.plan = RenderPlan(config: first, sampleRate: configuredSampleRate,
                                 trainer: currentTrainer, pickup: currentPickup)
            $0.songPlan = nil
            $0.running = true
            $0.resetRequested = true
        }
        let changeFrame = Int((changeAtSeconds * configuredSampleRate).rounded())
        let total = Int((totalSeconds * configuredSampleRate).rounded())
        var samples = try drainOfflineRender(totalFrames: changeFrame)
        update(second)   // publish the new config; the render callback re-anchors on the next block
        samples += try drainOfflineRender(totalFrames: max(0, total - changeFrame))
        return (samples, changeFrame)
    }

    /// Pumps AVAudioEngine's offline manual rendering for `totalFrames` frames and returns channel-0
    /// samples. Shared by the single-tempo and song offline renderers so both drive the identical
    /// pull loop.
    private func drainOfflineRender(totalFrames: Int) throws -> [Float] {
        let capacity = avEngine.manualRenderingMaximumFrameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avEngine.manualRenderingFormat,
                                            frameCapacity: capacity) else {
            throw EngineError.bufferAllocationFailed
        }

        var samples = [Float]()
        samples.reserveCapacity(totalFrames)
        var rendered = 0
        while rendered < totalFrames {
            let need = AVAudioFrameCount(min(Int(capacity), totalFrames - rendered))
            let status = try avEngine.renderOffline(need, to: buffer)
            guard status == .success else { break }
            let produced = Int(buffer.frameLength)
            if produced == 0 { break }
            if let ch0 = buffer.floatChannelData?[0] {
                for i in 0..<produced { samples.append(ch0[i]) }
            }
            rendered += produced
        }
        return samples
    }

    func teardownOfflineRendering() {
        if avEngine.isRunning { avEngine.stop() }
        avEngine.disableManualRenderingMode()
        isManualRendering = false
    }

    // MARK: - Render callback (AUDIO THREAD)

    private static func silence(_ abl: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(abl) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    private func render(frameCount: AVAudioFrameCount,
                        into abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
        let frames = Int(frameCount)

        // Snapshot the published control (tiny critical section). Copying the `[[Float]]` tables is a
        // COW retain, not an allocation.
        var running = false
        var didReset = false
        var plan: RenderPlan?
        var songPlan: SongPlan?
        var selectedTable: [[Float]] = []
        var pickupTable: [[Float]] = []
        var voiceTable: [[Float]] = []
        var voiceSyllableTable: [[Float]] = []
        var classicTable: [[Float]] = []
        var voiceMode = false
        var speakSubdivisions = true
        var voiceVolume = 1.0
        control.withLockUnchecked { c in
            running = c.running
            plan = c.plan
            songPlan = c.songPlan
            selectedTable = c.clickTable
            pickupTable = c.pickupTable
            voiceTable = c.voiceTable
            voiceSyllableTable = c.voiceSyllableTable
            classicTable = c.classicTable
            voiceMode = c.voiceMode
            speakSubdivisions = c.speakSubdivisions
            voiceVolume = c.voiceVolume
            if c.resetRequested { c.resetRequested = false; didReset = true }
        }
        atSelectedTable = selectedTable
        atPickupTable = pickupTable
        atVoiceTable = voiceTable
        atVoiceSyllableTable = voiceSyllableTable
        atClassicTable = classicTable
        atVoiceMode = voiceMode
        atSpeakSubdivisions = speakSubdivisions
        atVoiceVolume = voiceVolume

        // Start from silence; voices/ticks mix in additively.
        for buffer in ablPtr {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        if didReset {
            atState.framesElapsed = 0
            atState.nextTick = 0
            atState.epochFrame = 0
            atState.nextClickIndex = 0
            atState.songFinishedPublished = false
            atPlan = nil                    // force a fresh anchor on the first plan after the reset
            for i in atState.voices.indices { atState.voices[i].active = false }
        }

        guard running, !atClassicTable.isEmpty else {
            return noErr    // paused (or buffers not ready): output silence, do not advance the grid
        }

        let blockStart = atState.framesElapsed
        let blockEnd = blockStart + frames

        // Where a still-sounding spoken token (a number or subdivision syllable) must be hard-cut: the
        // next *spoken* onset in this block, so consecutive counts ("1", "e", "and", "a") never overlap.
        // Computed only in single-tempo Voice mode — otherwise it stays `.max` and every voice mixes
        // exactly as before, so the accuracy-critical click path is byte-for-byte unchanged. A ringing
        // number is left alone under a following *click* (e.g. a clicked subdivision) — only a spoken
        // onset replaces it.
        var spokenCutOffset = Int.max
        if atVoiceMode, songPlan == nil, let p = atPlan {
            spokenCutOffset = firstSpokenOnsetOffset(plan: p, blockStart: blockStart, blockEnd: blockEnd)
        }

        // 1) Continue voices still sounding from earlier blocks. A spoken token is hard-cut at the next
        // spoken onset so it can't bleed into the next count; clicks ring out unchanged.
        for vi in atState.voices.indices where atState.voices[vi].active {
            let cut = (atVoiceMode && isSpokenTable(atState.voices[vi].table)) ? spokenCutOffset : Int.max
            mix(voiceIndex: vi, into: ablPtr, startFrame: 0, frameCount: frames, hardCutAt: cut)
        }

        // 2) Trigger every onset falling within this block: [blockStart, blockEnd).

        if let songPlan {
            // Song mode: walk the pre-expanded click stream by index. Same voice scheduling as below;
            // only the onset/accent source differs (an array lookup instead of the closed form).
            let count = songPlan.clickCount
            var idx = atState.nextClickIndex
            while idx < count {
                let onset = songPlan.frame(at: idx)
                if onset >= blockEnd { break }
                let offset = onset - blockStart
                if offset >= 0 {
                    let level = songPlan.accent(at: idx)
                    // Song mode always uses the classic click (table 2). The selected timbre/voice is a
                    // single-tempo choice, so songs sound exactly as they always have. A muted beat emits
                    // no click but still publishes its pulse so the count/visual advance.
                    if level != .muted {
                        triggerVoice(table: 2, bufferIndex: level.rawValue, at: offset,
                                     into: ablPtr, frameCount: frames, cutVoices: false)
                    }
                    publishSongPulse(plan: songPlan, index: idx, level: level)
                }
                idx += 1
            }
            atState.nextClickIndex = idx
            // End of song: all clicks consumed and the playhead has reached the song's full length.
            if idx >= count, !atState.songFinishedPublished, blockEnd >= songPlan.totalFrames {
                atState.songFinishedPublished = true
                publishSongFinished()
            }
        } else if let plan {
            // A new plan published mid-playback (a live tempo/meter/subdivision/accent change) is
            // re-anchored so the running schedule continues seamlessly — no gap, no double-trigger, and
            // no drift introduced at the switch. After a reset `atPlan` is nil, so the first plan anchors
            // at the current position.
            if plan !== atPlan {
                anchorPlanSwap(to: plan, blockStart: blockStart)
                atPlan = plan
            }

            var tick = atState.nextTick
            while true {
                let onset = atState.epochFrame + plan.frame(forTick: tick)
                if onset >= blockEnd { break }
                let offset = onset - blockStart
                if offset >= 0 {
                    let level = plan.accentLevel(forTick: tick)
                    // The gap-click trainer decides whether this beat sounds. It never shifts the onset —
                    // only whether a voice fires — so the grid stays sample-accurate. `.play` when the
                    // trainer is off (the default), so the path below is unchanged.
                    let gate = plan.trainerGate(forTick: tick)
                    // A muted beat (or a trainer-silenced one) emits no click / speaks no number, but the
                    // pulse below is always published so the count and the on-screen beat keep advancing.
                    if level != .muted && gate != .silence {
                        if gate == .softDownbeat {
                            // Trainer gap bar: keep only a soft downbeat as a reference, reusing the quiet
                            // `.weak` buffer of the selected timbre (table 0 is the classic click in Voice
                            // mode too), so you don't lose the bar.
                            triggerVoice(table: 0, bufferIndex: AccentLevel.weak.rawValue, at: offset,
                                         into: ablPtr, frameCount: frames, cutVoices: false)
                        } else if atVoiceMode {
                            // Voice mode: speak the number/syllable for this tick exactly on its frame,
                            // cutting any still-sounding previous spoken token. As the tempo rises the count
                            // gracefully degrades (RenderPlan.voiceDetail): a sixteenth "1 e and a" first
                            // drops the "e"/"a" to clicks (speak "1 . and ."), then drops to beat-numbers-only
                            // — so a spoken token is never hard-cut mid-word and the count is never lost. The
                            // user's "beats only" preference and unmapped ticks (tuplets/32nds) click too.
                            var token = plan.voiceToken(forTick: tick)
                            if case .syllable = token,
                               !atSpeakSubdivisions || !plan.speaksSubdivision(forTick: tick) {
                                token = .none
                            }
                            scheduleVoiceToken(token, level: level, at: offset,
                                               into: ablPtr, frameCount: frames)
                        } else {
                            // Click mode: a pickup / count-in tick uses the distinct pickup timbre (table 4)
                            // at its natural accent level — so the lead-in is a "different tune" without ever
                            // being louder than the downbeat; every other tick uses the selected timbre
                            // (table 0). Same onset frame, so timing is byte-for-byte unchanged.
                            let clickTableId = plan.isPickup(forTick: tick) ? 4 : 0
                            triggerVoice(table: clickTableId, bufferIndex: level.rawValue, at: offset,
                                         into: ablPtr, frameCount: frames, cutVoices: false)
                        }
                    }
                    publishPulse(tick: tick, plan: plan, level: level)
                }
                tick += 1
            }
            atState.nextTick = tick
        }

        atState.framesElapsed = blockEnd
        return noErr
    }

    /// Re-anchors the audio-thread schedule when the single-tempo plan is swapped mid-playback, so the
    /// change takes effect promptly without a gap, a double-trigger, or any drift at the switch point.
    ///
    /// `anchor` is the frame of the next click that was already about to fire under the *old* plan (it is
    /// ≥ `blockStart` and has not sounded yet). We keep that click on time and re-derive everything after
    /// it from the new plan:
    ///  * **Phase-compatible change** (same meter *and* subdivision — e.g. a BPM or accent/sound change):
    ///    the beat/tick phase is preserved (`nextTick` unchanged); only the spacing after `anchor`
    ///    changes. This is the BPM-slider case — the pulse keeps its place in the bar.
    ///  * **Structural change** (meter or subdivision changed): the tick grid means something different,
    ///    so the new pattern rebuilds from a fresh downbeat (`nextTick = 0`) at the next safe boundary.
    ///
    /// Within each segment onsets are `epochFrame + round(tick × framesPerTick)` — the same closed form
    /// the accuracy tests prove — and `epochFrame`/`anchor` are always whole samples, so no segment
    /// drifts and the join is sample-exact.
    private func anchorPlanSwap(to new: RenderPlan, blockStart: Int) {
        guard let old = atPlan else {
            // First plan after a reset (or the very first plan): anchor tick 0 at the current position.
            atState.epochFrame = blockStart
            atState.nextTick = 0
            return
        }
        let oldNextOnset = atState.epochFrame + old.frame(forTick: atState.nextTick)
        let anchor = max(oldNextOnset, blockStart)
        if old.beatsPerBar == new.beatsPerBar && old.ticksPerBeat == new.ticksPerBeat {
            atState.epochFrame = anchor - new.frame(forTick: atState.nextTick)   // preserve phase
        } else {
            atState.epochFrame = anchor                                          // restart the bar
            atState.nextTick = 0
        }
    }

    /// Schedules the Voice sound for one tick: a spoken number (table 1) or subdivision syllable
    /// (table 3), cutting the previous spoken token so words don't slur; a click fallback (table 0) when
    /// the token is `.none` or its buffer has not rendered (e.g. a headless environment).
    private func scheduleVoiceToken(_ token: VoiceToken, level: AccentLevel, at offset: Int,
                                    into abl: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        switch token {
        case .number(let i):
            if i >= 0, i < atVoiceTable.count, !atVoiceTable[i].isEmpty {
                triggerVoice(table: 1, bufferIndex: i, at: offset,
                             into: abl, frameCount: frameCount, cutVoices: true)
                return
            }
        case .syllable(let s):
            let idx = s.rawValue
            if idx < atVoiceSyllableTable.count, !atVoiceSyllableTable[idx].isEmpty {
                triggerVoice(table: 3, bufferIndex: idx, at: offset,
                             into: abl, frameCount: frameCount, cutVoices: true)
                return
            }
        case .none:
            break
        }
        triggerVoice(table: 0, bufferIndex: level.rawValue, at: offset,
                     into: abl, frameCount: frameCount, cutVoices: false)
    }

    private func triggerVoice(table: Int, bufferIndex: Int, at offset: Int,
                              into abl: UnsafeMutableAudioBufferListPointer, frameCount: Int,
                              cutVoices: Bool) {
        if cutVoices {
            // Start a short release on any still-sounding spoken token (number OR syllable) so the next
            // one replaces it cleanly (a fade, not a hard stop, so there is no click at fast tempo).
            for i in atState.voices.indices
            where atState.voices[i].active && isSpokenTable(atState.voices[i].table) && atState.voices[i].fadeRemaining < 0 {
                atState.voices[i].fadeRemaining = voiceReleaseFrames
            }
        }
        var slot = -1
        for i in atState.voices.indices where !atState.voices[i].active { slot = i; break }
        if slot == -1 { slot = 0 }    // pool exhausted (won't happen in practice): steal slot 0
        atState.voices[slot] = Voice(bufferIndex: bufferIndex, playhead: 0, active: true,
                                     table: table, fadeRemaining: -1)
        mix(voiceIndex: slot, into: abl, startFrame: offset, frameCount: frameCount)
    }

    /// The buffer a voice reads from, by table id: 0 = selected click timbre, 1 = spoken number,
    /// 2 = classic click (song mode / fallback), 3 = spoken subdivision syllable, 4 = pickup click (the
    /// selected timbre pitch-shifted).
    private func voiceBuffer(table: Int, index: Int) -> [Float]? {
        switch table {
        case 1:  return atVoiceTable.indices.contains(index) ? atVoiceTable[index] : nil
        case 2:  return atClassicTable.indices.contains(index) ? atClassicTable[index] : nil
        case 3:  return atVoiceSyllableTable.indices.contains(index) ? atVoiceSyllableTable[index] : nil
        case 4:  return atPickupTable.indices.contains(index) ? atPickupTable[index] : nil
        default: return atSelectedTable.indices.contains(index) ? atSelectedTable[index] : nil
        }
    }

    /// A "spoken" voice — a number (table 1) or a syllable (table 3) — as opposed to a click. Successive
    /// spoken tokens cross-fade so they never slur; clicks are left to ring.
    @inline(__always)
    private func isSpokenTable(_ table: Int) -> Bool { table == 1 || table == 3 }

    /// The block-relative offset of the next tick in this block that *speaks* (a beat number, always, or a
    /// subdivision syllable when the tempo/preference allows), or `.max` if none. Ticks that merely click
    /// (a clicked subdivision, a trainer soft-downbeat, a muted/silenced pulse) are skipped, so a spoken
    /// number keeps ringing under them and is cut only when the *next spoken* count is about to sound.
    /// Cheap: it advances at most a couple of ticks (onsets are far wider than an audio block at any
    /// speakable tempo). Audio-thread only; reads the same immutable plan the render loop schedules from.
    private func firstSpokenOnsetOffset(plan: RenderPlan, blockStart: Int, blockEnd: Int) -> Int {
        var tick = atState.nextTick
        while true {
            let onset = atState.epochFrame + plan.frame(forTick: tick)
            if onset >= blockEnd { return Int.max }
            if onset >= blockStart {
                let level = plan.accentLevel(forTick: tick)
                let gate = plan.trainerGate(forTick: tick)
                if level != .muted && gate == .play {
                    // `isBeat`/`speaksSubdivision(forTick:)` are pickup-shifted, so a pickup subdivision that
                    // speaks (e.g. a spoken "& of 4") is correctly treated as a spoken onset.
                    if plan.isBeat(forTick: tick) {
                        return onset - blockStart                       // a beat: speaks its number
                    } else if atSpeakSubdivisions && plan.speaksSubdivision(forTick: tick),
                              case .syllable = plan.voiceToken(forTick: tick) {
                        return onset - blockStart                       // a spoken subdivision syllable
                    }
                }
            }
            tick += 1
        }
    }

    /// Mixes one voice's remaining samples into the block starting at `startFrame`, advancing its
    /// playhead and deactivating it when exhausted. A voice with `fadeRemaining >= 0` is played through
    /// a linear release ramp and cut when the ramp completes. At full gain (`fadeRemaining < 0`) this is
    /// the original click mix, sample-for-sample.
    ///
    /// `hardCutAt` (block-relative frame, `.max` == none) stops a spoken token dead at the next spoken
    /// onset with a couple-ms declick, so consecutive counts never overlap. Used *only* for spoken voices
    /// in Voice mode; every other call passes `.max` and takes the original path, byte-for-byte unchanged.
    private func mix(voiceIndex vi: Int, into abl: UnsafeMutableAudioBufferListPointer,
                     startFrame: Int, frameCount: Int, hardCutAt: Int = .max) {
        guard let click = voiceBuffer(table: atState.voices[vi].table,
                                      index: atState.voices[vi].bufferIndex) else {
            atState.voices[vi].active = false
            return
        }
        let playhead = atState.voices[vi].playhead
        let remaining = click.count - playhead
        guard remaining > 0 else { atState.voices[vi].active = false; return }
        let n = min(remaining, frameCount - startFrame)
        guard n > 0 else { return }

        let fade = atState.voices[vi].fadeRemaining
        let releaseLen = max(voiceReleaseFrames, 1)
        // Spoken tokens (numbers/syllables) are scaled by the voice volume; clicks stay at unity gain, so
        // the sample-accurate click path is byte-for-byte unchanged (default voiceVolume == 1.0 anyway).
        let voiceGain: Float = isSpokenTable(atState.voices[vi].table) ? Float(atVoiceVolume) : 1.0

        // Hard-cut path (Voice mode only): mix up to the cut with a short declick, then stop this token —
        // it is being replaced by the next count. Wholly separate so the default path below stays exact.
        if hardCutAt != .max {
            let mixN = min(n, max(0, hardCutAt - startFrame))
            if mixN > 0 {
                let declick = max(voiceHardCutFrames, 1)
                click.withUnsafeBufferPointer { src in
                    for buffer in abl {
                        guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for k in 0..<mixN {
                            var gain: Float = voiceGain
                            if fade >= 0 {
                                let f = fade - k
                                if f <= 0 { break }
                                gain *= Float(f) / Float(releaseLen)
                            }
                            let toCut = mixN - k                 // frames until the hard cut
                            if toCut < declick { gain *= Float(toCut) / Float(declick) }
                            base[startFrame + k] += src[playhead + k] * gain
                        }
                    }
                }
            }
            atState.voices[vi].playhead = playhead + mixN
            atState.voices[vi].active = false                    // replaced at the next onset — done
            return
        }

        click.withUnsafeBufferPointer { src in
            for buffer in abl {
                guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if fade < 0 {
                    for k in 0..<n {
                        base[startFrame + k] += src[playhead + k] * voiceGain
                    }
                } else {
                    // Release ramp: gain falls from (fade/releaseLen) to 0 across the remaining frames.
                    for k in 0..<n {
                        let f = fade - k
                        guard f > 0 else { break }
                        base[startFrame + k] += src[playhead + k] * (Float(f) / Float(releaseLen)) * voiceGain
                    }
                }
            }
        }

        atState.voices[vi].playhead = playhead + n
        if fade >= 0 {
            let newFade = fade - n
            atState.voices[vi].fadeRemaining = newFade
            if newFade <= 0 { atState.voices[vi].active = false; return }
        }
        if atState.voices[vi].playhead >= click.count { atState.voices[vi].active = false }
    }

    private func publishPulse(tick: Int, plan: RenderPlan, level: AccentLevel) {
        let beat = plan.beatIndex(forTick: tick)
        pulse.withLockUnchecked { p in
            p.sequence &+= 1
            p.tickIndex = tick
            p.beatIndex = beat
            p.accent = level
            p.sectionIndex = nil
            p.barInSection = nil
            p.songFinished = false
        }
    }

    private func publishSongPulse(plan: SongPlan, index: Int, level: AccentLevel) {
        let beat = plan.beatInBar(at: index)
        let section = plan.sectionIndex(at: index)
        let bar = plan.barInSection(at: index)
        pulse.withLockUnchecked { p in
            p.sequence &+= 1
            p.tickIndex = index
            p.beatIndex = beat
            p.accent = level
            p.sectionIndex = section
            p.barInSection = bar
            p.songFinished = false
        }
    }

    private func publishSongFinished() {
        pulse.withLockUnchecked { p in
            p.sequence &+= 1          // bump so the UI poll notices even though no new click sounded
            p.songFinished = true
        }
    }
}
