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

    // MARK: Immutable audio data (generated once per sample rate, then read lock-free)

    private var clickTable: [[Float]] = []

    // MARK: Shared state (main <-> audio thread)

    private struct Control {
        var plan: RenderPlan?
        /// Non-nil ⇒ song mode: the render callback walks this pre-expanded click stream instead of
        /// the single-tempo `plan`. Exactly one of the two is active at a time.
        var songPlan: SongPlan?
        var running = false
        var resetRequested = false
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
    }
    private final class AudioThreadState {
        var framesElapsed = 0
        var nextTick = 0
        /// Song-mode cursor: the index of the next click to consider in `SongPlan`.
        var nextClickIndex = 0
        /// One-shot guard so the end-of-song pulse is published exactly once.
        var songFinishedPublished = false
        var voices = [Voice](repeating: Voice(), count: 16)
    }
    private let atState = AudioThreadState()

    // MARK: Current configuration (main thread)

    private(set) var currentConfig = MetronomeConfiguration()
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
        let plan = RenderPlan(config: config, sampleRate: configuredSampleRate)
        control.withLock { $0.plan = plan }
    }

    // MARK: - Real-time transport

    /// Starts (or restarts) the single-tempo click from tick 0. Clears any song plan so the two modes
    /// never both drive the callback.
    func start() throws {
        guard !isManualRendering else { return }
        try ensureRealtimeEngineRunning()
        let plan = RenderPlan(config: currentConfig, sampleRate: configuredSampleRate)
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
        clickTable = ClickSoundFactory.makeClickTable(sampleRate: sampleRate)

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
            $0.plan = RenderPlan(config: config, sampleRate: configuredSampleRate)
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

        // Snapshot the published control (tiny critical section).
        var running = false
        var didReset = false
        var plan: RenderPlan?
        var songPlan: SongPlan?
        control.withLockUnchecked { c in
            running = c.running
            plan = c.plan
            songPlan = c.songPlan
            if c.resetRequested { c.resetRequested = false; didReset = true }
        }

        // Start from silence; voices/ticks mix in additively.
        for buffer in ablPtr {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        if didReset {
            atState.framesElapsed = 0
            atState.nextTick = 0
            atState.nextClickIndex = 0
            atState.songFinishedPublished = false
            for i in atState.voices.indices { atState.voices[i].active = false }
        }

        guard running, !clickTable.isEmpty else {
            return noErr    // paused: keep outputting silence, do not advance the grid
        }

        // 1) Continue voices still sounding from earlier blocks.
        for vi in atState.voices.indices where atState.voices[vi].active {
            mix(voiceIndex: vi, into: ablPtr, startFrame: 0, frameCount: frames)
        }

        // 2) Trigger every onset falling within this block: [blockStart, blockEnd).
        let blockStart = atState.framesElapsed
        let blockEnd = blockStart + frames

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
                    triggerVoice(bufferIndex: level.rawValue, at: offset,
                                 into: ablPtr, frameCount: frames)
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
            var tick = atState.nextTick
            while true {
                let onset = plan.frame(forTick: tick)
                if onset >= blockEnd { break }
                let offset = onset - blockStart
                if offset >= 0 {
                    let level = plan.accentLevel(forTick: tick)
                    triggerVoice(bufferIndex: level.rawValue, at: offset,
                                 into: ablPtr, frameCount: frames)
                    publishPulse(tick: tick, plan: plan, level: level)
                }
                tick += 1
            }
            atState.nextTick = tick
        }

        atState.framesElapsed = blockEnd
        return noErr
    }

    private func triggerVoice(bufferIndex: Int, at offset: Int,
                              into abl: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        var slot = -1
        for i in atState.voices.indices where !atState.voices[i].active { slot = i; break }
        if slot == -1 { slot = 0 }    // pool exhausted (won't happen with short clicks): steal slot 0
        atState.voices[slot] = Voice(bufferIndex: bufferIndex, playhead: 0, active: true)
        mix(voiceIndex: slot, into: abl, startFrame: offset, frameCount: frameCount)
    }

    /// Mixes one voice's remaining samples into the block starting at `startFrame`, advancing its
    /// playhead and deactivating it when exhausted.
    private func mix(voiceIndex vi: Int, into abl: UnsafeMutableAudioBufferListPointer,
                     startFrame: Int, frameCount: Int) {
        let bufIndex = atState.voices[vi].bufferIndex
        guard clickTable.indices.contains(bufIndex) else {
            atState.voices[vi].active = false
            return
        }
        let click = clickTable[bufIndex]                 // hoist inner array (one retain per block)
        let playhead = atState.voices[vi].playhead
        let remaining = click.count - playhead
        guard remaining > 0 else { atState.voices[vi].active = false; return }
        let n = min(remaining, frameCount - startFrame)
        guard n > 0 else { return }

        click.withUnsafeBufferPointer { src in
            for buffer in abl {
                guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for k in 0..<n {
                    base[startFrame + k] += src[playhead + k]
                }
            }
        }

        let newPlayhead = playhead + n
        atState.voices[vi].playhead = newPlayhead
        if newPlayhead >= click.count { atState.voices[vi].active = false }
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
