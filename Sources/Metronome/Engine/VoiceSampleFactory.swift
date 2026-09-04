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
        let voice = bestVoice()   // enhanced/premium when installed, else the best available English voice
        var table: [[Float]] = []
        table.reserveCapacity(maxNumber)
        for n in 1...maxNumber {
            table.append(renderOne(String(n), synth: synth, voice: voice, sampleRate: sampleRate))
        }
        // If synthesis produced nothing at all, report failure so the engine keeps using clicks.
        return table.allSatisfy(\.isEmpty) ? [] : table
    }

    /// Renders the counting syllables ("and", "e", "a", "trip", "let") to mono Float buffers at
    /// `sampleRate`, indexed by `VoiceSyllable.rawValue`. Identical pipeline to `renderSpokenNumbers`
    /// (offline synth → convert to the engine format → trim so the syllable's onset is at frame 0), so a
    /// scheduled syllable lands audibly on its subdivision tick. Returns `[]` if nothing synthesized, so
    /// the engine falls back to clicking the subdivisions.
    static func renderSyllables(sampleRate: Double) -> [[Float]] {
        guard sampleRate > 0 else { return [] }
        let synth = AVSpeechSynthesizer()
        let voice = bestVoice()
        let cases = VoiceSyllable.allCases
        var table = [[Float]](repeating: [], count: cases.count)
        for s in cases {
            let raw = renderOne(s.spokenText, synth: synth, voice: voice, sampleRate: sampleRate)
            // Syllables ("e", "and", "a", …) are aggressively compacted so they fit inside a fast
            // subdivision tick and finish before the next one — the engine additionally hard-cuts the
            // previous count at the next onset, so together they never slur or overlap.
            table[s.rawValue] = compactSyllable(raw, sampleRate: sampleRate)
        }
        return table.allSatisfy(\.isEmpty) ? [] : table
    }

    /// A brisk speaking rate — a touch above the system default so each count is punchy and short (which
    /// also helps it fit inside a fast beat), capped at the platform maximum.
    static var speechRate: Float {
        min(AVSpeechUtteranceDefaultSpeechRate * 1.15, AVSpeechUtteranceMaximumSpeechRate)
    }
    /// A slightly raised pitch reads as crisper and cuts through better than the default drone.
    static let pitchMultiplier: Float = 1.06

    private static func renderOne(_ text: String,
                                  synth: AVSpeechSynthesizer,
                                  voice: AVSpeechSynthesisVoice?,
                                  sampleRate: Double) -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Faster + punchier, and no dead air around the word so the syllable is as short as possible.
        utterance.rate = speechRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

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

        return trimSilence(resampleToMonoFloat(chunks, targetRate: sampleRate))
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

    /// Trims near-silence from **both** ends: the leading trim puts the word's onset at frame 0 (so the
    /// audible syllable lands exactly on the beat frame when the engine schedules the buffer there), and
    /// the trailing trim drops the dead tail so the token is as short as possible — the difference between
    /// a slow, laggy count and a tight one, and what lets a syllable fit inside a fast beat. Internal dips
    /// below threshold (e.g. between the two parts of a word) are preserved; only the outer silence goes.
    /// All-silence (nothing synthesized) returns empty, which the engine reads as "no buffer → click".
    static func trimSilence(_ samples: [Float], threshold: Float = 0.02) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else { return [] }
        if first == 0 && last == samples.count - 1 { return samples }
        return Array(samples[first...last])
    }

    /// Tightens a counting *syllable* buffer for fast subdivision counting: trims outer near-silence a hair
    /// more aggressively than a number (so the token starts crisply at frame 0 and drops its dead tail),
    /// then caps the total length so a syllable comfortably fits inside a subdivision tick, with a short
    /// fade at the cap so the truncation never clicks. The onset stays at frame 0, so a scheduled syllable
    /// still lands exactly on its tick. Returns `[]` for all-silence (⇒ the engine clicks the tick).
    static func compactSyllable(_ samples: [Float],
                                sampleRate: Double,
                                maxSeconds: Double = 0.13,
                                threshold: Float = 0.03) -> [Float] {
        let trimmed = trimSilence(samples, threshold: threshold)
        guard !trimmed.isEmpty, sampleRate > 0 else { return trimmed }
        let maxFrames = max(1, Int(maxSeconds * sampleRate))
        guard trimmed.count > maxFrames else { return trimmed }

        var capped = Array(trimmed[0..<maxFrames])
        // Fade the last few ms to zero so a hard length cap never introduces a click.
        let fade = min(capped.count, max(1, Int(0.004 * sampleRate)))
        let start = capped.count - fade
        for j in 0..<fade {
            capped[start + j] *= Float(fade - j) / Float(fade)
        }
        return capped
    }

    // MARK: - Voice selection (prefer a natural, high-quality voice)

    /// A speech voice reduced to just what ranking needs, so the "prefer enhanced/premium, prefer en-US"
    /// choice is a pure function that can be unit-tested without a synthesizer or a device voice catalog.
    struct VoiceCandidate: Equatable {
        let identifier: String
        let language: String
        /// 3 = premium, 2 = enhanced, 1 = default/compact — higher is more natural.
        let qualityRank: Int
    }

    /// Picks the best installed English voice: prefer higher synthesis quality (premium > enhanced >
    /// default), then a more-preferred locale, falling back to `en-US` if nothing better resolves. Chosen
    /// once per pre-render (never on the audio thread).
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceCandidate(identifier: $0.identifier, language: $0.language, qualityRank: qualityRank($0.quality))
        }
        if let best = rankBestVoice(candidates), let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-US")   // last resort (nil ⇒ system default)
    }

    /// Maps a system voice quality to a rank (higher = more natural). `.premium` is iOS 16+.
    static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1   // .default / compact
        }
    }

    /// Ranks candidates and returns the best, or `nil` if the list is empty. English voices are strongly
    /// preferred (the count is in English); among them, higher quality wins, then a more-preferred locale,
    /// with a stable identifier tiebreak so the choice is deterministic.
    static func rankBestVoice(_ candidates: [VoiceCandidate],
                              preferredLanguages: [String] = ["en-US", "en-GB", "en-AU", "en-IE", "en"]) -> VoiceCandidate? {
        let english = candidates.filter { $0.language.lowercased().hasPrefix("en") }
        let pool = english.isEmpty ? candidates : english
        return pool.max { a, b in
            if a.qualityRank != b.qualityRank { return a.qualityRank < b.qualityRank }
            let ra = languageRank(a.language, preferredLanguages)
            let rb = languageRank(b.language, preferredLanguages)
            if ra != rb { return ra > rb }              // larger rank index = less preferred = "smaller"
            return a.identifier > b.identifier          // stable, deterministic tiebreak
        }
    }

    /// Index of the first preferred language that `language` matches (exact, or a region of it, or the
    /// bare "en" catch-all); `preferred.count` when it matches none. Lower is more preferred.
    static func languageRank(_ language: String, _ preferred: [String]) -> Int {
        let lang = language.lowercased()
        for (i, p) in preferred.enumerated() {
            let pl = p.lowercased()
            if lang == pl || lang.hasPrefix(pl + "-") || (pl == "en" && lang.hasPrefix("en")) {
                return i
            }
        }
        return preferred.count
    }
}
