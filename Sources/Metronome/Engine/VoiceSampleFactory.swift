import AVFoundation

/// Loads the Voice-mode audio — spoken beat numbers ("one", "two", …) and subdivision syllables
/// ("and", "e", "a", "trip", "let") — from PRE-GENERATED, permissively-licensed clips bundled with the
/// app, decodes them to PCM once, and hands them to the engine, which schedules them sample-accurately
/// on each onset frame — exactly like a click buffer, never via a per-beat synthesizer call.
///
/// ## Why bundled clips, not live speech
/// The Voice sound used to pre-render each utterance on device with `AVSpeechSynthesizer`. That was
/// robotic, varied device-to-device, and each utterance was too long to land cleanly on a fast
/// subdivision (a 16th "1 e and a" would smear/overlap). Pre-trimmed bundled clips fix all three:
/// identical on every phone, and short/punchy enough that a whole "1 e and a" plays without slurring.
///
/// The clips are generated off-device by `tools/generate_voice_samples.py` with Piper
/// (voice **en_US-joe-medium** — OHF-Voice "joe" dataset, **CC0**; a warm, clear male voice fine-tuned from
/// the natural en_US *lessac* base), and ship as `Resources/Voice/voice_*.wav` (mono 16-bit PCM, 22.05 kHz):
/// `voice_1`…`voice_32` speak the beat numbers, `voice_and/e/a/trip/let` the subdivision syllables.
///
/// ## How
///  1. Each clip is read from the app bundle into an `AVAudioPCMBuffer` (in the file's own format).
///  2. It is converted to the engine's format — **mono Float32 at `sampleRate`** — with a single
///     `AVAudioConverter` pass, so the buffer mixes into the render callback with no per-sample work.
///  3. Leading/trailing near-silence is trimmed (numbers) / the syllable is compacted (syllables) so the
///     spoken onset is at frame 0 of the buffer. That is what makes the *audible* token land on the beat
///     frame when the engine schedules the buffer there (the ONSET requirement).
///
/// This is **never** called on the audio thread and never by the accuracy tests — `MetronomeEngine`
/// loads the table lazily on a background queue only when Voice is actually selected. If a clip is
/// missing (e.g. a unit-test bundle that does not carry the app's resources), it returns `[]` and the
/// engine simply falls back to clicks — so the count is never lost.
enum VoiceSampleFactory {

    /// Loads spoken numbers `1...maxNumber` as mono Float buffers at `sampleRate`. The result is
    /// 0-indexed: element `i` is the spoken number `i + 1` (so beat index 0 → "one"). Returns `[]` if
    /// nothing could be loaded (⇒ the engine keeps using clicks).
    static func renderSpokenNumbers(upTo maxNumber: Int, sampleRate: Double) -> [[Float]] {
        guard maxNumber >= 1, sampleRate > 0 else { return [] }
        var table: [[Float]] = []
        table.reserveCapacity(maxNumber)
        for n in 1...maxNumber {
            // Align the spoken word's PERCEPTUAL onset to frame 0 — not merely its acoustic onset. A
            // consonant-initial number ("seven", "six") has a soft lead-in before its vowel, so trimming
            // only silence still leaves the *perceived* beat (the vowel) tens of ms late — which is why
            // the count read "a skosh slow". `alignPerceptualOnset` shaves that sub-perceptual lead-in
            // (bounded, so a strong consonant is never gutted) so the count lands ON the beat.
            table.append(alignPerceptualOnset(loadClip(named: "voice_\(n)", sampleRate: sampleRate),
                                              sampleRate: sampleRate))
        }
        // If nothing loaded at all (e.g. resources absent), report failure so the engine keeps clicking.
        return table.allSatisfy(\.isEmpty) ? [] : table
    }

    /// Loads the counting syllables ("and", "e", "a", "trip", "let") as mono Float buffers at
    /// `sampleRate`, indexed by `VoiceSyllable.rawValue`. Each is compacted (onset at frame 0, hard length
    /// cap with a fade) so it fits inside a fast subdivision tick and finishes before the next one — the
    /// engine additionally hard-cuts the previous count at the next onset, so together they never slur or
    /// overlap. Returns `[]` if nothing loaded, so the engine falls back to clicking the subdivisions.
    static func renderSyllables(sampleRate: Double) -> [[Float]] {
        guard sampleRate > 0 else { return [] }
        let cases = VoiceSyllable.allCases
        var table = [[Float]](repeating: [], count: cases.count)
        for s in cases {
            // Filename stem == `VoiceSyllable.spokenText` (voice_and/e/a/trip/let.wav).
            let raw = loadClip(named: "voice_\(s.spokenText)", sampleRate: sampleRate)
            table[s.rawValue] = compactSyllable(raw, sampleRate: sampleRate)
        }
        return table.allSatisfy(\.isEmpty) ? [] : table
    }

    // MARK: - Bundled-clip loading

    /// Anchors `Bundle(for:)` to this module so the loader can find the clips whether the code is running
    /// in the shipping app or linked into a unit-test bundle.
    private final class BundleToken {}

    /// The bundles to search for the Voice clips, most-likely first and de-duplicated. In the shipping app
    /// the resources live in `Bundle.main`; when this code is linked into a test bundle we also try the
    /// bundle it was loaded from, so a host that can see the resources exercises the real spoken path (and
    /// one that cannot simply gets `[]` → clicks).
    private static let candidateBundles: [Bundle] = {
        var seen = Set<String>()
        return [Bundle.main, Bundle(for: BundleToken.self)].filter { seen.insert($0.bundlePath).inserted }
    }()

    /// Reads a bundled clip (`<name>.wav`) and converts it to a single mono Float32 array at `sampleRate`.
    /// Runs off the audio thread (on the engine's background voice-render queue). Returns `[]` if the
    /// resource is absent or unreadable, which the caller reads as "no buffer → click".
    static func loadClip(named name: String, sampleRate: Double) -> [Float] {
        guard sampleRate > 0, let url = clipURL(named: name),
              let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else { return [] }
        do {
            try file.read(into: input)
        } catch {
            return []
        }
        guard input.frameLength > 0 else { return [] }
        return resampleToMonoFloat([input], targetRate: sampleRate)
    }

    /// Locates `<name>.wav` in the first candidate bundle that carries it, or `nil` if none do.
    private static func clipURL(named name: String) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: name, withExtension: "wav") { return url }
        }
        return nil
    }

    /// Converts PCM buffers (any format) to a single mono Float32 array at `targetRate` — one
    /// `AVAudioConverter` pass, so the buffer plays back at the right pitch/speed and needs no per-sample
    /// conversion in the render callback.
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
    /// All-silence (nothing loaded) returns empty, which the engine reads as "no buffer → click".
    static func trimSilence(_ samples: [Float], threshold: Float = 0.02) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else { return [] }
        if first == 0 && last == samples.count - 1 { return samples }
        return Array(samples[first...last])
    }

    /// Aligns a spoken NUMBER's **perceptual onset** (roughly the vowel — where the word becomes clearly
    /// audible) to frame 0, so the count lands ON the beat rather than a hair late.
    ///
    /// ## Why this exists (the "skosh slow" fix)
    /// `trimSilence` puts the *acoustic* onset at frame 0 — the very first faint sample of a leading
    /// consonant (its threshold is ~2% of peak). But a listener locks onto a word's **perceptual centre**,
    /// near the vowel onset, which for a consonant-initial number ("**s**even", "**s**ix", "**th**ree")
    /// arrives tens of ms after that faint start. Scheduling the acoustic onset on the beat therefore
    /// *sounds* late. Measuring the bundled clips confirmed they carry almost no untrimmed silence (raw vs
    /// trimmed differ by only a few ms), so the lateness is this perceptual-onset gap, not stray silence.
    ///
    /// ## What it does
    /// After trimming outer silence, it finds the first sample reaching `onsetFraction` of the clip's peak
    /// (the vowel/loud-body onset) and removes the sub-perceptual lead-in up to just before it — but never
    /// more than `maxLeadSeconds` (so a genuinely long, audible consonant is preserved, not gutted) — with
    /// a short fade-in so the cut can't click. The result's frame 0 is the *perceived* onset, which the
    /// engine then schedules on the beat. Adaptive per clip: a vowel-initial word ("eight", "eleven") is
    /// barely touched; a consonant-initial one is pulled forward up to the cap. At `maxLeadSeconds == 0`
    /// this is exactly `trimSilence` (the original behaviour), so it can be dialled off.
    static func alignPerceptualOnset(_ samples: [Float],
                                     sampleRate: Double,
                                     maxLeadSeconds: Double = 0.03,
                                     onsetFraction: Float = 0.30,
                                     guardSeconds: Double = 0.006) -> [Float] {
        let trimmed = trimSilence(samples)
        guard !trimmed.isEmpty, sampleRate > 0, maxLeadSeconds > 0 else { return trimmed }
        var peak: Float = 0
        for s in trimmed { peak = max(peak, abs(s)) }
        guard peak > 0 else { return trimmed }
        let threshold = onsetFraction * peak
        guard let perceptualOnset = trimmed.firstIndex(where: { abs($0) >= threshold }) else { return trimmed }
        let guardFrames = max(0, Int(guardSeconds * sampleRate))
        let maxLeadFrames = max(0, Int(maxLeadSeconds * sampleRate))
        // Trim up to just before the perceptual onset (keeping a short guard of the attack), bounded by
        // the max lead so a long consonant is never fully removed.
        let cut = min(max(0, perceptualOnset - guardFrames), maxLeadFrames)
        guard cut > 0 else { return trimmed }
        var result = Array(trimmed[cut...])
        // Fade the first couple of ms in so removing the lead-in can't introduce a click.
        let fade = min(result.count, max(1, Int(0.003 * sampleRate)))
        for j in 0..<fade {
            result[j] *= Float(j) / Float(fade)
        }
        return result
    }

    /// Tightens a counting *syllable* buffer for fast subdivision counting: trims outer near-silence a hair
    /// more aggressively than a number (so the token starts crisply at frame 0 and drops its dead tail),
    /// then caps the total length so a syllable comfortably fits inside a subdivision tick, with a short
    /// fade at the cap so the truncation never clicks. The onset stays at frame 0, so a scheduled syllable
    /// still lands exactly on its tick. Returns `[]` for all-silence (⇒ the engine clicks the tick).
    static func compactSyllable(_ samples: [Float],
                                sampleRate: Double,
                                maxSeconds: Double = 0.12,
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
}
