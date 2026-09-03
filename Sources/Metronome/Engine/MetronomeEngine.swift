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
        var running = false
        var resetRequested = false
    }
    private let control = OSAllocatedUnfairLock(initialState: Control())

    /// The most recent click the audio thread emitted, for the visual beat indicator. The UI polls
    /// this (e.g. via a display link / timer) and reacts when `sequence` advances.
    struct BeatPulse: Equatable {
        var sequence: UInt64 = 0
        var tickIndex: Int = -1
        var beatIndex: Int?
        var accent: AccentLevel = .normal
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
        var voices = [Voice](repeating: Voice(), count: 16)
    }
    private let atState = AudioThreadState()

    // MARK: Current configuration (main thread)

    private(set) var currentConfig = MetronomeConfiguration()
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

    /// Starts (or restarts) the click from tick 0.
    func start() throws {
        guard !isManualRendering else { return }
        try ensureRealtimeEngineRunning()
        let plan = RenderPlan(config: currentConfig, sampleRate: configuredSampleRate)
        control.withLock {
            $0.plan = plan
            $0.running = true
            $0.resetRequested = true
        }
        setRunning(true)
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
            try? self.start()                  // rebuild session/engine and restart cleanly
        }
        session.onRouteChange = { [weak self] reason in
            guard let self else { return }
            switch reason {
            case .oldDeviceUnavailable:
                // e.g. headphones unplugged — pause rather than surprise the room via the speaker.
                if self.isRunning { self.stop() }
            case .newDeviceAvailable, .routeConfigurationChange, .override, .categoryChange:
                if self.isRunning, self.session.sampleRate != self.configuredSampleRate {
                    try? self.start()          // sample rate changed: rebuild at the new rate
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
            if self.isRunning { try? self.start() }
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

    /// Renders `seconds` of audio offline and returns channel-0 float samples. The returned array's
    /// index is the absolute frame from playback start, so onsets can be measured directly.
    func renderOffline(config: MetronomeConfiguration, seconds: Double) throws -> [Float] {
        update(config)
        control.withLock {
            $0.plan = RenderPlan(config: config, sampleRate: configuredSampleRate)
            $0.running = true
            $0.resetRequested = true
        }

        let sr = configuredSampleRate
        let totalFrames = Int((seconds * sr).rounded())
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
        control.withLockUnchecked { c in
            running = c.running
            plan = c.plan
            if c.resetRequested { c.resetRequested = false; didReset = true }
        }

        // Start from silence; voices/ticks mix in additively.
        for buffer in ablPtr {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        if didReset {
            atState.framesElapsed = 0
            atState.nextTick = 0
            for i in atState.voices.indices { atState.voices[i].active = false }
        }

        guard running, let plan, !clickTable.isEmpty else {
            return noErr    // paused: keep outputting silence, do not advance the grid
        }

        // 1) Continue voices still sounding from earlier blocks.
        for vi in atState.voices.indices where atState.voices[vi].active {
            mix(voiceIndex: vi, into: ablPtr, startFrame: 0, frameCount: frames)
        }

        // 2) Trigger every tick whose onset falls within this block: [blockStart, blockEnd).
        let blockStart = atState.framesElapsed
        let blockEnd = blockStart + frames
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
        }
    }
}
