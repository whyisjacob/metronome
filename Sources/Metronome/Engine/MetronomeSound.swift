import Foundation

/// The metronome's chosen sound. Two families:
///  - **Click timbres** (`.classic`, `.woodblock`, `.beep`, `.rimshot`, `.cowbell`) are synthesized in
///    code by `ClickSoundFactory` — no audio assets. They play the same 3-buffer accent table
///    (strong / normal / weak) as the original click, so they slot into the render path unchanged.
///  - **`.voice`** speaks the beat number each beat ("one, two, three…"). The spoken numbers are
///    pre-rendered to PCM once (see `VoiceSampleFactory`) and scheduled by `MetronomeEngine` on the
///    exact beat frame, identically to a click.
///
/// The set is deliberately a flat, `CaseIterable` enum so adding a timbre is a one-line change here
/// plus a spec in `ClickSoundFactory` — nothing in the engine needs to know the roster.
///
/// `.classic` is the default and the sound the accuracy tests drive; `.voice` never touches those
/// tests (they never select it, and voice buffers are rendered lazily, never at engine init).
enum MetronomeSound: String, CaseIterable, Identifiable, Codable, Hashable {
    case classic
    case woodblock
    case beep
    case rimshot
    case cowbell
    case voice

    var id: String { rawValue }

    /// `true` for the spoken-number mode; the click timbres return `false`.
    var isVoice: Bool { self == .voice }

    /// The click timbres in display order (everything except `.voice`).
    static let clickCases: [MetronomeSound] = [.classic, .woodblock, .beep, .rimshot, .cowbell]

    var displayName: String {
        switch self {
        case .classic:   return "Click"
        case .woodblock: return "Woodblock"
        case .beep:      return "Beep"
        case .rimshot:   return "Rimshot"
        case .cowbell:   return "Cowbell"
        case .voice:     return "Voice"
        }
    }

    /// An SF Symbol name for a compact control (a missing symbol renders as nothing, never a crash).
    var symbolName: String {
        switch self {
        case .classic:   return "metronome"
        case .woodblock: return "square.grid.2x2"
        case .beep:      return "waveform"
        case .rimshot:   return "circle.circle"
        case .cowbell:   return "bell"
        case .voice:     return "person.wave.2"
        }
    }
}
