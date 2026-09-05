import Foundation

/// The song-mode analogue of `RenderPlan`: an immutable, pre-expanded click stream for a whole
/// `Song`, published to the audio thread and read lock-free. Where `RenderPlan` describes a single,
/// endless tempo with a closed-form `frame(forTick:)`, a song's tempo/meter/subdivision change at
/// section boundaries, so the onsets cannot come from one formula — they are expanded once here into
/// flat, parallel arrays the render callback walks by index (`frame(at:)`, `accent(at:)`, …).
///
/// ## Zero cumulative drift across section boundaries — the whole point
/// Onsets are laid down with a running **integer** frame cursor:
///
///   * Within a section, click `i` (its local tick index) is placed at the **closed form**
///     `cursor + Int((Double(i) × sectionFramesPerTick).rounded())`. Because it is `i × fpt` (never a
///     running sum of per-tick durations), the error versus continuous time is ≤ ½ sample for *every*
///     `i` and never accumulates — identical in spirit to `RenderPlan.frame(forTick:)`.
///   * At a boundary the cursor advances by the section's **total integer sample length**, rounding
///     the section duration to whole samples exactly **once**:
///     `cursor += Int((Double(totalTicks) × sectionFramesPerTick).rounded())`.
///
/// So every section starts on an integer sample boundary computable independently as the sum of the
/// earlier sections' rounded lengths; the next section's first click (`i == 0`) lands exactly on that
/// cursor. There is no compounding fractional error, and the tempo/meter/subdivision switch takes
/// effect precisely on that first click.
///
/// The per-section framesPerTick is grouped as `secondsPerTick × sampleRate` and then multiplied by
/// `Double(i)` before rounding — the same grouping `RenderPlan`/`MetronomeConfiguration` use — so the
/// float arithmetic is bit-for-bit what the single-tempo path (and the offline accuracy oracle)
/// produce for the same tempo/subdivision.
final class SongPlan {

    let sampleRate: Double

    // Parallel, index-aligned arrays — one entry per click, in playback order. Primitive element
    // types (Int / trivial enum) so the audio thread reads them with no allocation or ARC traffic.
    private let frames: [Int]
    private let accents: [AccentLevel]
    private let sectionIndices: [Int]
    /// 0-based bar index *within its own section* (spans repeats: bar 0…totalBars-1).
    private let barIndices: [Int]
    /// Beat-within-bar (0-based) for a beat click, or `-1` for a between-beats subdivision click.
    private let beatIndices: [Int]
    /// The Voice token for each click (empty when the plan carries no voice). Computed per section from the
    /// SAME `RenderPlan.voiceToken` the single-tempo path uses, so song counting can never disagree with it.
    private let voiceTokens: [VoiceToken]
    /// Whether each click SPEAKS its token (vs clicks) when its section's Voice is on — a beat number always
    /// speaks; a subdivision syllable speaks only when its section speaks subdivisions AND the tempo allows
    /// (the same `RenderPlan` degrade as single-tempo). Empty when the plan carries no voice.
    private let speaksTokens: [Bool]
    /// The resolved per-section Voice / counting settings (`nil` = no voice: every section clicks, exactly
    /// as before). Kept so the engine and the seek path can ask "does section s count out loud?".
    let voice: SongVoicePlan?

    /// Absolute integer sample frame at which each section begins (`sectionStartFrames[s]`), plus a
    /// final entry equal to `totalFrames`. Independent-of-callback bookkeeping, handy for tests/UI.
    let sectionStartFrames: [Int]
    /// Number of clicks contributed by each section (index-aligned to `song.sections`).
    let sectionClickCounts: [Int]
    /// Whole length of the song in samples — the sum of every section's rounded integer length.
    let totalFrames: Int

    init(song: Song, sampleRate: Double, voice: SongVoicePlan? = nil) {
        self.sampleRate = sampleRate
        self.voice = voice

        var frames: [Int] = []
        var accents: [AccentLevel] = []
        var sectionIndices: [Int] = []
        var barIndices: [Int] = []
        var beatIndices: [Int] = []
        var starts: [Int] = []
        var counts: [Int] = []
        // Voice tokens are built ONLY when a voice plan is supplied — otherwise these stay empty and the
        // render path is byte-for-byte the classic-click song (the accuracy oracle uses the no-voice path).
        var voiceTokens: [VoiceToken] = []
        var speaksTokens: [Bool] = []

        // Rough reserve to avoid repeated growth for large songs.
        let estimate = song.sections.reduce(0) { $0 + $1.totalTicks }
        frames.reserveCapacity(estimate)
        accents.reserveCapacity(estimate)
        sectionIndices.reserveCapacity(estimate)
        barIndices.reserveCapacity(estimate)
        beatIndices.reserveCapacity(estimate)
        if voice != nil { voiceTokens.reserveCapacity(estimate); speaksTokens.reserveCapacity(estimate) }

        var cursor = 0
        for (s, section) in song.sections.enumerated() {
            starts.append(cursor)

            let fpt = section.framesPerTick(sampleRate: sampleRate)   // secondsPerTick × sampleRate
            let tpb = section.ticksPerBeat
            let ticksPerBar = section.ticksPerBar
            let beatsPerBar = section.beatsPerBar
            let totalTicks = section.totalTicks
            let pattern = section.accentPattern

            let swing = section.swing
            let cell = section.cell
            // A throwaway single-tempo plan for THIS section's grid, consulted only for Voice tokens — it
            // reuses the audited `voiceToken`/`speaksSubdivision` code, so song counting is identical to the
            // single-tempo count for the same meter/subdivision/tempo. Built once per section (off the audio
            // thread) and only when the plan carries voice.
            let voicePlan: RenderPlan? = voice != nil
                ? RenderPlan(config: section.configuration, sampleRate: sampleRate) : nil
            let sectionSpeaksSubs = voice?.speakSubdivisions(section: s) ?? false
            for i in 0..<totalTicks {
                // Closed form from the integer cursor: no per-tick accumulation → no intra-section drift.
                // Swing rides the SAME `SwingGrid` the single-tempo path uses; at `swing == 0` it is
                // exactly `round(i × fpt)`, so a straight section is byte-for-byte unchanged. On-beats never
                // move, so section length (the cursor advance below) is unaffected by swing.
                frames.append(cursor + SwingGrid.frame(forTick: i, ticksPerBeat: tpb,
                                                       framesPerTick: fpt, swing: swing))

                let tickWithinBar = i % ticksPerBar
                let beat = tickWithinBar / tpb                         // beat this tick belongs to
                let posInBeat = tickWithinBar % tpb
                let onBeat = posInBeat == 0
                let beatAccent = pattern.indices.contains(beat) ? pattern[beat] : .normal
                beatIndices.append(onBeat ? beat : -1)                 // -1 for a between-beats click
                if beatAccent == .muted {
                    accents.append(.muted)                            // whole beat silent (engine skips it)
                } else if cell.silences(posInBeat: posInBeat, ticksPerBeat: tpb) {
                    accents.append(.muted)                            // cell-silenced sub-position (no-op when .straight)
                } else if onBeat {
                    accents.append(beatAccent.audioLevel)             // strong / medium / normal
                } else {
                    accents.append(.weak)                             // subdivision click
                }
                sectionIndices.append(s)
                barIndices.append(i / ticksPerBar)

                // Voice tokens (only when the plan carries voice). The token is what to SAY on this click;
                // `speaks` folds the section's speak-subdivisions preference and the tempo degrade, so the
                // engine just reads the two arrays. Onset frames/accents above are untouched — Voice changes
                // WHAT sounds, never WHEN — so the accuracy oracle (no-voice path) is byte-for-byte intact.
                if let vp = voicePlan {
                    let token = vp.voiceToken(forTick: i)
                    voiceTokens.append(token)
                    switch token {
                    case .number:   speaksTokens.append(true)                 // a beat number always speaks
                    case .syllable: speaksTokens.append(sectionSpeaksSubs && vp.speaksSubdivision(forTick: i))
                    case .none:     speaksTokens.append(false)                // 32nd/tuplet -> click
                    }
                }
            }

            counts.append(totalTicks)
            // Advance by the section's total length, rounded to whole samples exactly ONCE.
            cursor += Int((Double(totalTicks) * fpt).rounded())
        }

        starts.append(cursor)      // sentinel = end of song, so sectionStartFrames[s+1] is valid
        self.frames = frames
        self.accents = accents
        self.sectionIndices = sectionIndices
        self.barIndices = barIndices
        self.beatIndices = beatIndices
        self.voiceTokens = voiceTokens
        self.speaksTokens = speaksTokens
        self.sectionStartFrames = starts
        self.sectionClickCounts = counts
        self.totalFrames = cursor
    }

    // MARK: - Read API (audio thread reads these by index; all O(1), allocation-free)

    var clickCount: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }
    /// Number of sections in the expanded plan.
    var sectionCount: Int { sectionClickCounts.count }

    /// Index of the first click of section `s` in the flat stream — the seek target for "jump to section".
    /// Clamped so an out-of-range section maps to the song start / end sensibly.
    @inline(__always) func firstClickIndex(ofSection s: Int) -> Int {
        guard s > 0 else { return 0 }
        let upTo = min(s, sectionClickCounts.count)
        return sectionClickCounts[0..<upTo].reduce(0, +)
    }

    @inline(__always) func frame(at i: Int) -> Int { frames[i] }
    @inline(__always) func accent(at i: Int) -> AccentLevel { accents[i] }
    @inline(__always) func sectionIndex(at i: Int) -> Int { sectionIndices[i] }
    @inline(__always) func barInSection(at i: Int) -> Int { barIndices[i] }
    /// Beat-within-bar for a beat click, or `nil` for a subdivision click.
    @inline(__always) func beatInBar(at i: Int) -> Int? {
        let b = beatIndices[i]
        return b >= 0 ? b : nil
    }

    // MARK: - Voice (song counting) — all safe when the plan carries no voice (return "off" / click)

    /// Whether section `s` counts out loud (its resolved Voice setting). `false` when the plan has no voice.
    @inline(__always) func voiceEnabled(section s: Int) -> Bool { voice?.voiceEnabled(section: s) ?? false }
    /// Whether section `s` speaks its subdivision syllables (its resolved setting; `true` without voice).
    @inline(__always) func speakSubdivisions(section s: Int) -> Bool { voice?.speakSubdivisions(section: s) ?? true }
    /// Whether the click at flat index `i` is in a section that counts out loud.
    @inline(__always) func voiceEnabled(at i: Int) -> Bool { voiceEnabled(section: sectionIndices[i]) }
    /// The Voice token to utter on click `i` (`.none` when the plan has no voice → the engine clicks).
    @inline(__always) func voiceToken(at i: Int) -> VoiceToken {
        voiceTokens.indices.contains(i) ? voiceTokens[i] : .none
    }
    /// Whether click `i` SPEAKS its token (vs clicks) when its section's Voice is on. `false` without voice.
    @inline(__always) func speaksToken(at i: Int) -> Bool {
        speaksTokens.indices.contains(i) ? speaksTokens[i] : false
    }
}
