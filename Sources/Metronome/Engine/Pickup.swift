import Foundation

/// A **pickup (anacrusis) / count-in**: `ticks` incomplete-bar clicks sounded BEFORE the first real
/// downbeat, as a one-time lead-in.
///
/// ## Design — it's just the bar's own tail, started early
/// A pickup is **not** a separate counting/accent path. It is simply the bar's own tick stream started
/// partway through: play the last `ticks` ticks of a bar (bar-relative ticks `ticksPerBar − ticks … ticksPerBar − 1`),
/// then hit tick 0 — the STRONG downbeat "1" — and loop normally forever after. Concretely, playback tick
/// `t` maps to the ongoing bar-stream's **extended tick** `e = t + (ticksPerBar − ticks)`, and every
/// per-tick decision (`voiceToken`, `accentLevel`, `beatIndex`, swing via `frame`) is taken on `e` by the
/// **already-proven** machinery. So the count numbers, the "e/&/a/trip/let" subdivision syllables, the
/// internal group-head accents, and the swing positions all fall out for free — nothing is re-derived.
///
/// ## Why ticks, not beats
/// Denominating in ticks makes sub-beat pickups free — the single most common real-world case. A 1-tick
/// pickup on an eighth grid is the classic **"& of 4"** in 4/4; on a sixteenth grid a 2-tick pickup is
/// "and, a"; on a triplet grid a 1-tick pickup is "let". Odd meters and compound meters (where a "beat" is
/// a 3-tick dotted quarter) also work with no special-casing.
///
/// ## Accents & sound
/// The pickup ticks are the bar's TAIL, which never includes tick 0, so they are inherently non-`strong`
/// (they inherit the bar's real tail accents — e.g. a 7/8 2+2+3 group head stays `medium`), and the first
/// real downbeat after the pickup is `strong`. The "different tune" is a distinct **timbre/pitch at the
/// tick's natural (weak/normal/medium) gain** — never louder — applied by the engine to pickup ticks.
///
/// ## Looping — once only
/// In notation an anacrusis borrows its length from the incomplete FINAL bar of the phrase; a metronome
/// has no final bar to borrow from, so replaying the pickup each cycle would inject phantom beats and
/// corrupt the bar length — the one thing a metronome must never do. So the pickup plays exactly ONCE
/// (only playback ticks `0 … ticks−1`); after the first downbeat the metronome loops the full bar.
struct Pickup: Equatable {
    /// Pickup length in CURRENT-GRID TICKS (0 = off). The UI clamps this to `1 … ticksPerBar−1`;
    /// `effectiveTicks(ticksPerBar:)` re-clamps defensively so a stale value can never reach a full bar.
    var ticks: Int

    init(ticks: Int = 0) { self.ticks = max(0, ticks) }

    /// The "off" pickup — the default everywhere, so a `RenderPlan` built without one behaves byte-for-byte
    /// as before.
    static let none = Pickup()

    var isEnabled: Bool { ticks > 0 }

    /// The pickup length actually usable in a bar of `B` ticks: at most `B − 1` (a pickup is an *incomplete*
    /// bar — one full bar or more is a count-in, not an anacrusis), and 0 for a 1-tick bar.
    func effectiveTicks(ticksPerBar B: Int) -> Int {
        guard B > 1 else { return 0 }
        return min(max(ticks, 0), B - 1)
    }

    /// The bar-relative tick where playback begins (the extended tick of playback tick 0) — i.e.
    /// `ticksPerBar − effectiveTicks`. This is the amount every playback tick is shifted by.
    func startTick(ticksPerBar B: Int) -> Int { B - effectiveTicks(ticksPerBar: B) }

    /// The ongoing bar-stream ("extended") tick for playback tick `t`: `t + (B − ticks)` when enabled, or
    /// `t` unchanged when off. Feeding this to the normal per-tick functions yields the pickup for free.
    func extendedTick(_ t: Int, ticksPerBar B: Int) -> Int {
        let p = effectiveTicks(ticksPerBar: B)
        guard p > 0 else { return t }
        return t + (B - p)
    }

    /// Whether playback tick `t` is a pickup (lead-in) tick — the first `effectiveTicks` ticks, once.
    func isPickupTick(_ t: Int, ticksPerBar B: Int) -> Bool {
        let p = effectiveTicks(ticksPerBar: B)
        return p > 0 && t >= 0 && t < p
    }
}
