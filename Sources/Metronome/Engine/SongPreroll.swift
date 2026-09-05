import Foundation

/// A one-time count-in / pickup **lead-in**, scheduled BEFORE a song's first click (a song-start pickup)
/// or before a seek target (a section pickup) — and NEVER during continuous playback. A pickup is an
/// anacrusis: a metronome has no incomplete final bar to borrow it from, so replaying it on every pass
/// through a section would inject phantom beats and corrupt the bar length. So the main `SongPlan` click
/// stream contains no pickup ticks at all; this transient lead-in is layered in only at the start/seek.
///
/// ## It is the target bar's own tail, computed by the PROVEN single-tempo machinery
/// The lead-in is the last `p` ticks of the target section's first bar — exactly the single-tempo `Pickup`
/// case. So it is read straight out of a throwaway single-tempo `RenderPlan` built for the section's
/// configuration with `Pickup(ticks: p)`: its playback ticks `0 ..< p` ARE the lead-in. Their frames come
/// from the shared `SwingGrid` closed form (swing-correct, drift-free), their accents are the bar's real
/// tail accents (a tail tick is never the downbeat, so never the *strong* beat — clamped defensively), and
/// their Voice tokens are the tail-of-bar count ("…3, 4"; the "& of 4"; a triplet "let"; …) — nothing is
/// re-derived here. Playback tick `p` is the downbeat itself, so the distance from the first pickup tick to
/// the downbeat is exactly `RenderPlan.frame(forTick: p)`.
///
/// ## Anchoring
/// The clicks are re-anchored so the downbeat coincides with the section's real first click at absolute
/// frame `downbeatFrame` (the same timeline as `SongPlan.frame(at:)`): pickup tick `j` sits at
/// `downbeatFrame − span + rp.frame(forTick: j)`, where `span == rp.frame(forTick: p)`. The first pickup
/// tick is therefore `span` frames before the downbeat (possibly a negative absolute frame for a song-start
/// pickup — which is fine: the engine's frame cursor is relative, and offline capture simply begins on the
/// first pickup tick).
struct SongPreroll: Equatable {

    /// One lead-in click, ready for the engine to schedule.
    struct Click: Equatable {
        /// Absolute frame (same timeline as `SongPlan.frame(at:)`), anchored to the downbeat.
        let frame: Int
        /// The tick's natural tail-of-bar accent, clamped to never be `.strong` (a pickup is metrically
        /// weak; the downbeat that follows is the strong beat). A group head stays `.medium`.
        let accent: AccentLevel
        /// The tail-of-bar counting token for Voice mode ("…3, 4", "&", "a", "trip", "let", …).
        let token: VoiceToken
        /// Whether this token is SPOKEN (vs clicked) when the section's Voice is on: a beat number always
        /// speaks; a subdivision syllable speaks only when the section speaks subdivisions AND the tempo
        /// allows it (the same `RenderPlan` degrade the single-tempo path uses). Ignored in click mode.
        let speaks: Bool
    }

    /// The lead-in clicks in ascending-frame order (empty when there is no pickup).
    let clicks: [Click]
    /// Absolute frame of the downbeat this lead-in resolves to (== the section's real first click frame).
    let downbeatFrame: Int

    var isEmpty: Bool { clicks.isEmpty }

    /// The whole lead-in's length in frames (`downbeatFrame − first pickup tick`), 0 when empty. The engine
    /// starts its cursor `span` frames before the downbeat so the first pickup tick sounds immediately.
    var span: Int { clicks.first.map { downbeatFrame - $0.frame } ?? 0 }

    /// Builds the lead-in for `pickupTicks` ticks of `section` with the following downbeat pinned at
    /// `downbeatFrame`. `speakSubdivisions` is the section's RESOLVED preference (see `SongVoicePlan`).
    /// Returns an empty preroll (no clicks) when `pickupTicks` clamps to 0 or the rate is invalid.
    init(section: SongSection, pickupTicks: Int, downbeatFrame: Int, sampleRate: Double,
         speakSubdivisions: Bool = true) {
        self.downbeatFrame = downbeatFrame
        let p = Pickup(ticks: pickupTicks).effectiveTicks(ticksPerBar: section.ticksPerBar)
        guard p > 0, sampleRate > 0 else { clicks = []; return }

        // Reuse the audited single-tempo pickup path verbatim: playback ticks 0..<p are the lead-in, tick p
        // is the downbeat. `frame(forTick:)` already re-zeroes so the first pickup tick is at frame 0.
        let plan = RenderPlan(config: section.configuration, sampleRate: sampleRate, pickup: Pickup(ticks: p))
        let span = plan.frame(forTick: p)                       // first pickup tick -> downbeat distance
        clicks = (0..<p).map { j in
            let level = plan.accentLevel(forTick: j)
            let token = plan.voiceToken(forTick: j)
            let speaks: Bool
            switch token {
            case .number:   speaks = true                       // a beat number always speaks
            case .syllable: speaks = speakSubdivisions && plan.speaksSubdivision(forTick: j)
            case .none:     speaks = false                      // 32nd/tuplet -> click
            }
            return Click(frame: downbeatFrame - span + plan.frame(forTick: j),
                         accent: level == .strong ? .medium : level,   // a pickup tick is never the strong beat
                         token: token,
                         speaks: speaks)
        }
    }
}
