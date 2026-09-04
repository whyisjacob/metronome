import Foundation

/// What the Voice sound utters on a single tick: a spoken number, a counting syllable, or nothing (in
/// which case the engine clicks the tick instead).
///
/// It is pure data — computed by `RenderPlan.voiceToken(forTick:)` from the timing grid and consumed by
/// the engine's render callback — so the entire "which syllable lands on which tick" mapping is
/// unit-testable with no audio, no synthesizer, and no engine.
enum VoiceToken: Equatable {
    /// Speak a pre-rendered number buffer, 0-based (`0` → "one"). Used for beats and, in compound
    /// meters, for the dotted-quarter group heads (the group's ordinal).
    case number(Int)
    /// Speak a pre-rendered counting syllable ("e", "and", "a", "trip", "let").
    case syllable(VoiceSyllable)
    /// No spoken token for this tick — the engine falls back to a click (e.g. 32nd subdivisions, which
    /// have no concise standard syllable).
    case none
}

/// The non-number syllables of standard Western subdivision counting. The raw values are stable indices
/// into the engine's pre-rendered syllable-buffer table, so they must not be reordered.
///
///   * eighths  → "1 **and** 2 and …"
///   * sixteenths → "1 **e** **and** **a** 2 …"
///   * triplets → "1 **trip** **let** 2 …"
enum VoiceSyllable: Int, CaseIterable, Equatable {
    case and = 0   // the eighth off-beat ("and"), and the 3rd sixteenth
    case e         // the 2nd sixteenth ("e")
    case a         // the 4th sixteenth ("a")
    case trip      // the 2nd triplet / compound-group inner pulse ("trip")
    case letSub    // the 3rd triplet / compound-group inner pulse ("let")

    /// The text handed to the speech synthesizer to pre-render this syllable's PCM buffer.
    var spokenText: String {
        switch self {
        case .and:    return "and"
        case .e:      return "e"
        case .a:      return "a"
        case .trip:   return "trip"
        case .letSub: return "let"
        }
    }
}
