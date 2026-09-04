import AVFoundation

/// Pre-renders the spoken beat numbers ("one", "two", …) to PCM once, so the engine can schedule them
/// sample-accurately on each beat frame — exactly like a click buffer, never via a per-beat
/// `AVSpeechSynthesizer.speak` (which has unpredictable latency and could not land on the frame).
///
/// ## How
///  1. `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders each utterance offline into PCM chunks
///     in the synthesizer's own format (rate/int-or-float vary by OS/voice). A zero-length buffer marks
///     the end; a semaphore (with a timeout guard) waits for it on a background thread.
///  2. The chunks are converted to the engine's format — **mono Float32 at `sampleRate`** — with a
///     single `AVAudioConverter` pass, so the buffer plays back at the right pitch/speed and mixes into
///     the render callback with no per-sample conversion.
///  3. Leading near-silence is trimmed so the spoken word's onset is at frame 0 of the buffer. That is
///     what makes the *audible* number land on the beat frame when the engine schedules the buffer
///     there (the ONSET requirement), rather than a synthesizer-dependent number of silent samples late.
///
/// This is **never** called at engine init or on the audio thread, and never by the accuracy tests —
/// `MetronomeEngine` renders the table lazily on a background queue only when Voice is actually
/// selected. If synthesis is unavailable (e.g. a headless environment), it returns `[]` and the engine
/// simply falls back to clicks.
enum VoiceSampleFactory {

    /// Renders spoken numbers `1...maxNumber` to mono Float buffers at `sampleRate`. The result is
    /// 0-indexed: element `i` is the spoken number `i + 1` (so beat index 0 → "one"). Returns `[]` if
    /// nothing could be synthesized.
    static func renderSpokenNumbers(upTo maxNumber: Int, sampleRate: Double) -> [[Float]] {
        guard maxNumber >= 1, sampleRate > 0 else { return [] }
        let synth = AVSpeechSynthesizer()
        let voice = AVSpeechSynthesisVoice(language: "en-US")   // nil ⇒ system default voice
        var table: [[Float]] = []
        table.reserveCapacity(maxNumber)
        for n in 1...maxNumber {
            table.append(renderOne(String(n), synth: synth, voice: voice, sampleRate: sampleRate))
        }
        // If synthesis produced nothing at all, report failure so the engine keeps using clicks.
        return table.allSatisfy(\.isEmpty) ? [] : table
    }

    private static func renderOne(_ text: String,
                                  synth: AVSpeechSynthesizer,
                                  voice: AVSpeechSynthesisVoice?,
                                  sampleRate: Double) -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        var chunks: [AVAudioPCMBuffer] = []
        let done = DispatchSemaphore(value: 0)
        var finished = false

        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                if !finished { finished = true; done.signal() }
                return
            }
            chunks.append(pcm)
        }
        // Offline synthesis is fast; the timeout only guards against a callback that never signals.
        _ = done.wait(timeout: .now() + 5.0)

        return trimLeadingSilence(resampleToMonoFloat(chunks, targetRate: sampleRate))
    }

    /// Converts the synthesizer's chunks (any format) to a single mono Float32 array at `targetRate`.
    private static func resampleToMonoFloat(_ chunks: [AVAudioPCMBuffer], targetRate: Double) -> [Float] {
        guard let srcFormat = chunks.first?.format else { return [] }
        let srcTotal = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard srcTotal > 0 else { return [] }
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetRate,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return [] }

        let ratio = targetRate / srcFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(srcTotal) * ratio + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: capacity) else { return [] }

        var index = 0
        let input: AVAudioConverterInputBlock = { _, status in
            if index < chunks.count {
                status.pointee = .haveData
                let c = chunks[index]
                index += 1
                return c
            }
            status.pointee = .endOfStream
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: input)
        guard status != .error, let ch = out.floatChannelData?[0] else { return [] }

        let n = Int(out.frameLength)
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    /// Drops leading samples below `threshold` so the word's onset is at frame 0. Trailing silence is
    /// left as-is (harmless — it just decays after the beat).
    private static func trimLeadingSilence(_ samples: [Float], threshold: Float = 0.02) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }) else { return samples }
        return first == 0 ? samples : Array(samples[first...])
    }
}
