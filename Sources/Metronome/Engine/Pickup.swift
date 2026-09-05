import Foundation

/// A **pickup (anacrusis) / count-in**: `beats` incomplete-bar beats sounded BEFORE the first real
/// downbeat, as a one-time lead-in (optionally repeated before every bar).
///
/// ## The counting is the crux
/// A pickup is the *tail* of a bar, not "1". For a bar of `N` beats and a `k`-beat pickup, the pickup
/// beats count **N−k+1 … N**, and the first real beat after them is the STRONG downbeat "1":
///
///   * 4/4, k = 1 → "4";  k = 2 → "3, 4";  k = 3 → "2, 3, 4"
///   * 3/4, k = 1 → "3";  k = 2 → "2, 3"
///   * 2/4 / 2/2, k = 1 → "2"
///   * Compound (in the app's dotted-quarter beat unit): 6/8 counts in 2, so k = 1 → "2"; 12/8 counts in
///     4, so k = 1 → "4", k = 2 → "3, 4".
///
/// This is expressed by a single re-labeling of the global beat index `g` (0-based from playback start):
/// `beatInBar(g) = floorMod(g − k, N)`. For `g < k` (a pickup beat) that is `N − k + g` — the tail count;
/// for `g ≥ k` it is the normal loop with the downbeat at `g = k`. The onset *frames* are unchanged — a
/// pickup beat is just tick `g·ticksPerBeat` on the same sample-accurate grid — so `Pickup` is a pure
/// labeling overlay on `RenderPlan` (exactly like `GapTrainer`); it never touches the timing math.
///
/// The default is a **one-time** lead-in: the pickup occupies only global beats `0 … k−1`, so after the
/// first downbeat the metronome loops the full bar normally. `repeatsEachCycle` re-inserts the pickup
/// before every downbeat (period `k + N` beats) for practice.
struct Pickup: Equatable {
    /// Number of pickup beats (0 = off). The UI clamps this to `1 … beatsPerBar−1`; `effectiveBeats(_:)`
    /// re-clamps defensively so a stale value can never exceed the meter.
    var beats: Int
    /// When true, the pickup is re-inserted before every bar (each cycle), not just once. Default `false`
    /// — a pickup is a one-time lead-in.
    var repeatsEachCycle: Bool

    init(beats: Int = 0, repeatsEachCycle: Bool = false) {
        self.beats = max(0, beats)
        self.repeatsEachCycle = repeatsEachCycle
    }

    /// The "off" pickup — used as the default everywhere, so a `RenderPlan` built without one behaves
    /// byte-for-byte as before.
    static let none = Pickup()

    var isEnabled: Bool { beats > 0 }

    /// The pickup length actually usable in a meter of `N` beats: at most `N − 1` (a pickup is an
    /// *incomplete* bar, so it can never be a whole bar or more), and 0 for a 1-beat meter.
    func effectiveBeats(beatsPerBar N: Int) -> Int {
        guard N > 1 else { return 0 }
        return min(max(beats, 0), N - 1)
    }

    /// Non-negative modulo (Swift's `%` can be negative for a negative dividend, and pickup labeling
    /// evaluates `g − k` which is negative during the lead-in).
    private static func floorMod(_ a: Int, _ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let m = a % n
        return m >= 0 ? m : m + n
    }

    /// Whether global beat `g` (0-based from playback start) is a pickup (lead-in) beat — one of the beats
    /// sounded before the downbeat. Once mode: only `g < k`. Repeat mode: the first `k` beats of every
    /// `k + N` cycle.
    func isPickupBeat(globalBeat g: Int, beatsPerBar N: Int) -> Bool {
        let k = effectiveBeats(beatsPerBar: N)
        guard k > 0, g >= 0 else { return false }
        if repeatsEachCycle { return Self.floorMod(g, k + N) < k }
        return g < k
    }

    /// The beat-within-bar (0-based) global beat `g` should count as, accounting for the pickup shift.
    /// Pickup beats map to the TAIL of the bar (`N−k … N−1`); the first real downbeat maps to 0.
    /// With no pickup this is the plain `g mod N`.
    func beatInBar(globalBeat g: Int, beatsPerBar N: Int) -> Int {
        guard N > 0 else { return 0 }
        let k = effectiveBeats(beatsPerBar: N)
        guard k > 0 else { return Self.floorMod(g, N) }
        if repeatsEachCycle {
            let p = Self.floorMod(g, k + N)
            return p < k ? (N - k + p) : (p - k)
        }
        return Self.floorMod(g - k, N)
    }
}
