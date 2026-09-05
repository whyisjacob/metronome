import Foundation

/// The resolved per-section Voice / counting settings a `SongPlan` and the engine consult in song mode.
///
/// Song mode counting is the SAME machinery as the single-tempo path (spoken numbers on beats, the
/// "e / & / a / trip / let" syllables on subdivisions), gained here the ability to differ **per section**.
/// Each section either INHERITS the song-global default or OVERRIDES it:
///
///   * **voiceEnabled** — whether the section speaks its count. Inherits `Song.voiceEnabled` when the
///     section's own `voiceEnabled` override is `nil`.
///   * **speakSubdivisions** — whether the section speaks the in-between subdivision syllables (subject to
///     the tempo degrade, exactly as single-tempo). Inherits the app-global preference when the section's
///     `speakSubdivisions` override is `nil`.
///
/// The counted subdivision itself is each section's own `subdivision` (there is no grid-independent
/// "count in eighths on a quarter grid" — that is musically undefined against a fixed rhythmic grid), so
/// it is edited with the SAME shared subdivision control the rest of the app uses; there is no separate
/// counted-subdivision field.
///
/// Resolving inheritance here (once, off the audio thread) keeps `SongPlan`/`MetronomeEngine` free of the
/// `nil`-means-inherit logic: they see only concrete per-section booleans. Index-aligned to `song.sections`.
struct SongVoicePlan: Equatable {
    /// Whether each section speaks its count (else the classic click). Index-aligned to `song.sections`.
    let voiceEnabled: [Bool]
    /// Whether each section speaks its in-between subdivision syllables. Index-aligned to `song.sections`.
    let speakSubdivisions: [Bool]

    /// Resolves each section against the song-global default (`song.voiceEnabled`) and the app-global
    /// speak-subdivisions preference. A `nil` section override inherits; a non-`nil` one wins.
    static func resolve(song: Song, globalSpeakSubdivisions: Bool) -> SongVoicePlan {
        SongVoicePlan(
            voiceEnabled: song.sections.map { $0.voiceEnabled ?? song.voiceEnabled },
            speakSubdivisions: song.sections.map { $0.speakSubdivisions ?? globalSpeakSubdivisions })
    }

    /// Whether ANY section speaks — the engine renders the spoken-number buffers only when this is true.
    var anyVoiceEnabled: Bool { voiceEnabled.contains(true) }

    /// The effective "count out loud" resolution for one section (used by the section-editor UI to show
    /// "Voice: inherit (on)" vs an explicit override, and by the engine defensively for a bad index).
    func voiceEnabled(section s: Int) -> Bool { voiceEnabled.indices.contains(s) ? voiceEnabled[s] : false }
    func speakSubdivisions(section s: Int) -> Bool {
        speakSubdivisions.indices.contains(s) ? speakSubdivisions[s] : true
    }
}
