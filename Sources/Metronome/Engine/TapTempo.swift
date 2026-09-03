import Foundation

/// Turns a series of taps into a BPM, discarding outlier intervals so a stray early/late tap does
/// not skew the result. Pure and value-typed for direct unit testing (no clock is captured; the
/// caller supplies timestamps).
struct TapTempo {
    /// Timestamps (seconds, monotonic) of the retained recent taps.
    private(set) var taps: [Double] = []

    /// Maximum number of *intervals* to average over (so `maxIntervals + 1` timestamps).
    let maxIntervals: Int
    /// A gap longer than this (seconds) starts a fresh tapping session.
    let resetGap: Double

    init(maxIntervals: Int = 6, resetGap: Double = 2.0) {
        self.maxIntervals = max(1, maxIntervals)
        self.resetGap = resetGap
    }

    /// Registers a tap at `time` (seconds) and returns the current best BPM estimate, or `nil` if a
    /// single tap so far.
    mutating func addTap(at time: Double) -> Double? {
        if let last = taps.last, time - last > resetGap {
            taps.removeAll(keepingCapacity: true)   // stale — restart
        }
        taps.append(time)
        let maxCount = maxIntervals + 1
        if taps.count > maxCount {
            taps.removeFirst(taps.count - maxCount)
        }
        return TapTempo.bpm(fromTaps: taps)
    }

    mutating func reset() { taps.removeAll(keepingCapacity: true) }

    /// Pure: BPM from tap timestamps, discarding interval outliers around the median, clamped to the
    /// supported tempo range. Returns `nil` for fewer than two taps.
    static func bpm(fromTaps taps: [Double]) -> Double? {
        guard taps.count >= 2 else { return nil }

        var intervals: [Double] = []
        intervals.reserveCapacity(taps.count - 1)
        for i in 1..<taps.count {
            let d = taps[i] - taps[i - 1]
            if d > 0 { intervals.append(d) }
        }
        guard !intervals.isEmpty else { return nil }

        // Keep intervals within 50%..150% of the median (drops a doubled/halved stray tap), then
        // average the survivors.
        let median = intervals.sorted()[intervals.count / 2]
        let kept = intervals.filter { $0 >= median * 0.5 && $0 <= median * 1.5 }
        let use = kept.isEmpty ? intervals : kept
        let mean = use.reduce(0, +) / Double(use.count)
        guard mean > 0 else { return nil }

        return (60.0 / mean).clamped(to: MetronomeConfiguration.tempoRange)
    }
}
