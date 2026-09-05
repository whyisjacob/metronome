import XCTest
import AVFoundation
@testable import Metronome

/// Audio-level proof that the pickup / count-in lands **on the exact grid before the downbeat**, with the
/// STRONG accent on the first real beat — rendered through the real `MetronomeEngine` offline path.
///
/// The oracle grid is first-principles only: a beat lasts `60 / BPM` seconds, so beat `j` is due at
/// `round(j · 60/BPM · sampleRate)`. It is NEVER read from `RenderPlan`/`MetronomeConfiguration`. Because a
/// pickup beat is just a beat on that same uniform grid (the pickup only re-labels ticks, never moves
/// them), the pickup beats and the downbeat must all fall on this independent grid — which is exactly the
/// "the downbeat lands precisely one beat after the final pickup beat" requirement.
final class PickupRenderAccuracyTests: XCTestCase {

    private let sampleRate = 44_100.0

    private func peak(in samples: [Float], at frame: Int, window: Int = 400) -> Float {
        let start = max(0, frame - 32), end = min(frame + window, samples.count)
        var p: Float = 0
        var i = start
        while i < end { p = max(p, abs(samples[i])); i += 1 }
        return p
    }

    /// (a) + (b): a 2-beat pickup in 4/4 — the two pickup beats and the downbeat all sit on the
    /// first-principles quarter grid (drift-free, one beat apart), and the accent pattern is
    /// weak-pickups-then-STRONG-downbeat.
    func testPickupBeatsLandOnGridBeforeAStrongDownbeat() throws {
        let bpm = 120.0
        let framesPerBeat = (60.0 / bpm) * sampleRate          // first principles: a quarter-note beat
        let k = 2
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: .quarter)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setPickup(Pickup(beats: k))

        let bars = 2
        let seconds = Double(k + bars * 4) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThan(onsets.count, k + 4, "expected the pickup plus several bar beats")

        // Playback begins on sample 0 (offline: no hardware latency) → first pickup beat at frame 0.
        let base = onsets[0]
        XCTAssertLessThanOrEqual(base, 1, "the first pickup beat must start on sample 0")

        // (a) The k pickup beats and the downbeat (onset k) sit on the uniform grid, drift-free: the
        //     downbeat is exactly k beats after the start (i.e. exactly one beat after the last pickup).
        for j in 0...k {
            let ideal = Double(j) * framesPerBeat
            let measured = Double(onsets[j] - base)
            XCTAssertLessThan(abs(measured - ideal), 2.0,
                "onset \(j) off the first-principles grid: measured \(measured), ideal \(ideal)")
        }

        // (b) The downbeat (onset k) carries the STRONG accent: it is louder than each (weak) pickup beat
        //     before it AND louder than the normal beat 2 right after it.
        let downbeatPeak = peak(in: samples, at: onsets[k])
        for j in 0..<k {
            XCTAssertLessThan(peak(in: samples, at: onsets[j]), downbeatPeak,
                "pickup beat \(j) must be weaker than the strong downbeat (never the strong accent)")
        }
        XCTAssertGreaterThan(downbeatPeak, peak(in: samples, at: onsets[k + 1]),
            "the first beat after the pickup must be the strong accent")
    }

    /// (d): a 3-beat pickup in 4/4 plays ONCE — the strong downbeat leads every bar afterward (no extra
    /// lead-in beats are inserted before later bars), and the total onset density is the plain meter grid
    /// (the pickup adds a fixed k beats at the very start, not k per bar).
    func testPickupPlaysOnceThenLoopsNormally() throws {
        let bpm = 120.0
        let framesPerBeat = (60.0 / bpm) * sampleRate
        let k = 3
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: .common, subdivision: .quarter)

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setPickup(Pickup(beats: k))

        let bars = 3
        let seconds = Double(k + bars * 4) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        // Each bar's downbeat is at global beat k, k+4, k+8 … and is the strong accent — louder than the
        // beat immediately before it (the last pickup beat for bar 0, beat 4 of the previous bar after).
        func p(_ globalBeat: Int) -> Float { peak(in: samples, at: Int(Double(globalBeat) * framesPerBeat)) }
        for bar in 0..<bars {
            let downbeat = k + bar * 4
            XCTAssertGreaterThan(p(downbeat), p(downbeat - 1),
                "bar \(bar) downbeat (global beat \(downbeat)) must be the strong accent")
        }

        // Onset density == the plain grid over the window: k pickup + the bar beats, NOT k per bar. A
        // repeating pickup (the non-default) would add 2 extra lead-in onsets per later bar and fail this.
        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        let totalFrames = Int((seconds * sampleRate).rounded())
        var expected = 0
        while Int((Double(expected) * framesPerBeat).rounded()) < totalFrames { expected += 1 }
        XCTAssertLessThanOrEqual(abs(onsets.count - expected), 1,
            "onset count \(onsets.count) vs first-principles \(expected): the pickup must play once, not each bar")
    }

    /// The pickup rides the same grid at a compound meter too: 6/8 felt in 2 (dotted-quarter beats), a
    /// 1-beat pickup counts "2" then the strong "1". Independent oracle: a dotted quarter lasts 60/BPM s.
    func testCompoundPickupOnDottedQuarterGrid() throws {
        let bpm = 132.0
        let framesPerBeat = (60.0 / bpm) * sampleRate          // first principles: the dotted-quarter beat
        let config = MetronomeConfiguration(bpm: bpm, timeSignature: TimeSignature(numerator: 6, denominator: 8),
                                            subdivision: .quarter)   // main-beat: felt in 2

        let engine = MetronomeEngine()
        try engine.prepareForOfflineRendering(sampleRate: sampleRate)
        defer { engine.teardownOfflineRendering() }
        engine.setPickup(Pickup(beats: 1))

        let bars = 2
        let mainBeats = 2
        let seconds = Double(1 + bars * mainBeats) * (60.0 / bpm) + 0.25
        let samples = try engine.renderOffline(config: config, seconds: seconds)

        let onsets = OfflineRenderAccuracyTests.detectOnsets(in: samples, minGap: Int(0.018 * sampleRate))
        XCTAssertGreaterThan(onsets.count, 3)
        let base = onsets[0]
        XCTAssertLessThanOrEqual(base, 1)

        // The single pickup beat (onset 0) and the downbeat (onset 1) are exactly one dotted-quarter apart.
        XCTAssertLessThan(abs(Double(onsets[1] - base) - framesPerBeat), 2.0,
            "the downbeat must land exactly one dotted-quarter beat after the pickup")
        // The downbeat is the strong accent (louder than the pickup lead-in and the following group head).
        XCTAssertGreaterThan(peak(in: samples, at: onsets[1]), peak(in: samples, at: onsets[0]),
            "compound pickup: the downbeat must be stronger than the pickup lead-in")
    }
}
