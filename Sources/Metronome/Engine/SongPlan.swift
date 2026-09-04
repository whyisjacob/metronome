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

    /// Absolute integer sample frame at which each section begins (`sectionStartFrames[s]`), plus a
    /// final entry equal to `totalFrames`. Independent-of-callback bookkeeping, handy for tests/UI.
    let sectionStartFrames: [Int]
    /// Number of clicks contributed by each section (index-aligned to `song.sections`).
    let sectionClickCounts: [Int]
    /// Whole length of the song in samples — the sum of every section's rounded integer length.
    let totalFrames: Int

    init(song: Song, sampleRate: Double) {
        self.sampleRate = sampleRate

        var frames: [Int] = []
        var accents: [AccentLevel] = []
        var sectionIndices: [Int] = []
        var barIndices: [Int] = []
        var beatIndices: [Int] = []
        var starts: [Int] = []
        var counts: [Int] = []

        // Rough reserve to avoid repeated growth for large songs.
        let estimate = song.sections.reduce(0) { $0 + $1.totalTicks }
        frames.reserveCapacity(estimate)
        accents.reserveCapacity(estimate)
        sectionIndices.reserveCapacity(estimate)
        barIndices.reserveCapacity(estimate)
        beatIndices.reserveCapacity(estimate)

        var cursor = 0
        for (s, section) in song.sections.enumerated() {
            starts.append(cursor)

            let fpt = section.framesPerTick(sampleRate: sampleRate)   // secondsPerTick × sampleRate
            let tpb = section.ticksPerBeat
            let ticksPerBar = section.ticksPerBar
            let beatsPerBar = section.beatsPerBar
            let totalTicks = section.totalTicks
            let pattern = section.accentPattern

            for i in 0..<totalTicks {
                // Closed form from the integer cursor: no per-tick accumulation → no intra-section drift.
                frames.append(cursor + Int((Double(i) * fpt).rounded()))

                let tickWithinBar = i % ticksPerBar
                let beat = tickWithinBar / tpb                         // beat this tick belongs to
                let onBeat = tickWithinBar % tpb == 0
                let beatAccent = pattern.indices.contains(beat) ? pattern[beat] : .normal
                beatIndices.append(onBeat ? beat : -1)                 // -1 for a between-beats click
                if beatAccent == .muted {
                    accents.append(.muted)                            // whole beat silent (engine skips it)
                } else if onBeat {
                    accents.append(beatAccent.audioLevel)             // strong / medium / normal
                } else {
                    accents.append(.weak)                             // subdivision click
                }
                sectionIndices.append(s)
                barIndices.append(i / ticksPerBar)
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
        self.sectionStartFrames = starts
        self.sectionClickCounts = counts
        self.totalFrames = cursor
    }

    // MARK: - Read API (audio thread reads these by index; all O(1), allocation-free)

    var clickCount: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    @inline(__always) func frame(at i: Int) -> Int { frames[i] }
    @inline(__always) func accent(at i: Int) -> AccentLevel { accents[i] }
    @inline(__always) func sectionIndex(at i: Int) -> Int { sectionIndices[i] }
    @inline(__always) func barInSection(at i: Int) -> Int { barIndices[i] }
    /// Beat-within-bar for a beat click, or `nil` for a subdivision click.
    @inline(__always) func beatInBar(at i: Int) -> Int? {
        let b = beatIndices[i]
        return b >= 0 ? b : nil
    }
}
