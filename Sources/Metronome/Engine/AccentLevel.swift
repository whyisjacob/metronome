import Foundation

/// The relative emphasis of a single click. Selects both timbre (which generated sound) and gain.
///
/// The raw values are stable indices into the engine's immutable click-buffer table, so they must
/// not be reordered.
enum AccentLevel: Int, CaseIterable, Codable {
    /// An accented beat (e.g. the downbeat) — the brighter, louder "tock".
    case strong = 0
    /// An unaccented beat — the "tick".
    case normal = 1
    /// A subdivision click that falls between beats — a softer, quieter tick.
    case weak = 2
}
