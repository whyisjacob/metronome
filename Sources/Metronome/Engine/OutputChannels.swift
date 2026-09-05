import Foundation

/// The **mute / silent-practice** model: three independent output channels, and the one-tap presets that
/// compose them. Like `GapTrainer`, it is a deliberately **pure value type** with no audio or engine
/// dependency, so the whole muting policy is unit-testable with no synthesizer and no `AVAudioEngine`.
///
/// ## Muting changes only WHAT sounds, never WHEN
/// Each channel is a downstream *gate*, never a change to the schedule:
///  - **click** / **voice** are applied by `MetronomeEngine` as a GAIN of 0 in the mix (`setClickMuted` /
///    `setVoiceMuted`). The onset loop still places every tick at exactly `round(tick × framesPerTick)`,
///    still advances accents / pickups / sections, and still publishes a pulse for every tick — a muted
///    channel simply contributes 0 amplitude. When a channel is on, its gain is exactly `1.0` (clicks) or
///    the voice volume, so the sample-accurate click path is byte-for-byte what it was — the accuracy
///    suites, which never mute, render identical samples.
///  - **visual** is a *view* gate (`ContentView` reads it): the beat indicator + border-flash simply stop
///    reacting to the pulse. The engine keeps publishing the pulse regardless, so the beat state is always
///    correct and re-enabling visuals is instantaneous and in-phase.
struct OutputChannels: Equatable, Codable {
    /// The metronome click sound — every click timbre, plus the count-in / gap-trainer reference clicks.
    var click: Bool
    /// The spoken counting — beat numbers and the "e / and / a / trip / let" subdivision syllables.
    var voice: Bool
    /// The on-screen beat indicator (ball / dots / counter / ring) AND the screen-border flash.
    var visual: Bool

    /// Everything on — the unmuted default a fresh install starts from, so the engine and the accuracy
    /// tests are unaffected.
    static let full = OutputChannels(click: true, voice: true, visual: true)

    /// Whether any AUDIO is currently audible (click or voice). Visual is not audio, so it is excluded —
    /// this drives the "all audio muted" speaker icon and the running-but-silent badge.
    var anyAudioOn: Bool { click || voice }

    /// Whether every channel is on (the unmuted default).
    var isFull: Bool { click && voice && visual }
}

/// One-tap presets composed from the three channels — the silent-practice modes a musician reaches for
/// mid-rehearsal. `full` / `countOnly` / `flashOnly` are exactly the "just count" and "just flash" modes
/// the request asked for; the prominent speaker toggle flips between `full` and `flashOnly` ("mute all").
enum MutePreset: String, CaseIterable, Identifiable, Codable {
    /// Everything on: click + (spoken count, when the Voice sound is selected) + visual.
    case full
    /// "Just count": the spoken count and the visual, with the click muted.
    case countOnly
    /// "Just flash" — silent practice: the visual only, all audio muted. Internalise the pulse with no sound.
    case flashOnly

    var id: String { rawValue }

    /// The channel set this preset maps to. `visual` stays on in every preset — both requested modes
    /// (count-only and flash-only) rely on the on-screen beat.
    var channels: OutputChannels {
        switch self {
        case .full:      return OutputChannels(click: true,  voice: true,  visual: true)
        case .countOnly: return OutputChannels(click: false, voice: true,  visual: true)
        case .flashOnly: return OutputChannels(click: false, voice: false, visual: true)
        }
    }

    var displayName: String {
        switch self {
        case .full:      return "Full"
        case .countOnly: return "Count"
        case .flashOnly: return "Flash"
        }
    }

    var symbolName: String {
        switch self {
        case .full:      return "speaker.wave.2.fill"
        case .countOnly: return "person.wave.2.fill"
        case .flashOnly: return "bolt.fill"
        }
    }

    /// A short, unambiguous status line so a muted-but-running metronome never looks stopped.
    var statusLabel: String {
        switch self {
        case .full:      return "Full output — click, voice & visual"
        case .countOnly: return "Count only — click muted, counting aloud"
        case .flashOnly: return "Flash only — silent, the visual keeps the beat"
        }
    }

    /// The preset a given channel set corresponds to (for highlighting the selector), or `nil` when the
    /// channels are a custom combination not equal to any preset.
    static func matching(_ channels: OutputChannels) -> MutePreset? {
        allCases.first { $0.channels == channels }
    }
}
