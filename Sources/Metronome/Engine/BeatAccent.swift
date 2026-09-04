import Foundation

/// The user-chosen emphasis of a single **beat** in the bar. This is the per-beat editing model — the
/// thing a tap on a beat cell cycles through — as distinct from `AccentLevel`, which is the per-*tick*
/// value the audio engine uses to pick a click buffer (a beat's subdivisions are `.weak`, never a
/// `BeatAccent`).
///
/// Four states, cycled by tapping: **strong → medium → normal → muted → strong**.
///  - `strong`  — the primary accent (downbeat / group head): the loud "tock".
///  - `medium`  — a *secondary* accent, between strong and normal (e.g. 4/4 beat 3, compound group heads
///                other than the first): a distinct, in-between loudness.
///  - `normal`  — an unaccented beat: the plain "tick".
///  - `muted`   — silent: produces **no** click, but still advances the count and the on-screen beat.
///
/// ## Compatibility bridge
/// The app previously modelled accents as `[Bool]` (`true` == accented). To keep persisted data and the
/// large existing test-suite valid, `BeatAccent` is `ExpressibleByBooleanLiteral` (`true` → `.strong`,
/// `false` → `.normal`) and its `Codable` decodes a legacy JSON boolean as well as its own string form.
enum BeatAccent: String, CaseIterable, Hashable, Codable {
    case strong
    case medium
    case normal
    case muted

    /// The next state in the tap-to-cycle order (strong → medium → normal → muted → strong).
    var next: BeatAccent {
        switch self {
        case .strong: return .medium
        case .medium: return .normal
        case .normal: return .muted
        case .muted:  return .strong
        }
    }

    /// Whether this beat makes any sound (everything except `.muted`).
    var isAudible: Bool { self != .muted }

    /// The audio emphasis this beat's **on-beat** click uses. Subdivisions between beats are `.weak`
    /// (decided by the engine), never derived from here; a muted beat maps to `.muted` so the engine
    /// suppresses the click while still publishing the pulse.
    var audioLevel: AccentLevel {
        switch self {
        case .strong: return .strong
        case .medium: return .medium
        case .normal: return .normal
        case .muted:  return .muted
        }
    }

    /// A short label for the accent editor cell.
    var shortLabel: String {
        switch self {
        case .strong: return "Accent"
        case .medium: return "Medium"
        case .normal: return "Normal"
        case .muted:  return "Muted"
        }
    }

    // MARK: - Codable (tolerant of the legacy `[Bool]` representation)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Legacy data stored accents as booleans (true == accented). Honour that first.
        if let b = try? c.decode(Bool.self) {
            self = b ? .strong : .normal
            return
        }
        if let s = try? c.decode(String.self), let v = BeatAccent(rawValue: s) {
            self = v
            return
        }
        // Tolerate a bare integer index in declaration order, just in case.
        if let i = try? c.decode(Int.self), BeatAccent.allCases.indices.contains(i) {
            self = BeatAccent.allCases[i]
            return
        }
        self = .normal
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension BeatAccent: ExpressibleByBooleanLiteral {
    /// Compatibility bridge: a bare `true`/`false` in a `BeatAccent` context maps to `.strong`/`.normal`,
    /// so the earlier `[Bool]` accent literals keep compiling. Only affects literals, never variables.
    init(booleanLiteral value: Bool) { self = value ? .strong : .normal }
}
