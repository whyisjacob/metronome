import Foundation

/// The relative emphasis of a single click. Selects both timbre (which generated sound) and gain.
///
/// The raw values are stable indices into the engine's immutable click-buffer table, so they must
/// not be reordered. `strong`/`normal`/`weak` keep their original 0/1/2 indices so the click buffers
/// the accuracy tests depend on are byte-for-byte unchanged; `medium` and `muted` are appended.
enum AccentLevel: Int, CaseIterable, Codable {
    /// An accented beat (e.g. the downbeat) — the brighter, louder "tock".
    case strong = 0
    /// An unaccented beat — the "tick".
    case normal = 1
    /// A subdivision click that falls between beats — a softer, quieter tick.
    case weak = 2
    /// A *secondary* accent — between `strong` and `normal` in loudness (e.g. 4/4 beat 3, or the
    /// compound group heads other than the first).
    case medium = 3
    /// A muted beat — the engine emits **no** click for it (its buffer slot is silent) but still
    /// advances the count and the visual pulse.
    case muted = 4
    /// A **pickup / count-in** lead-in click — a distinct, unaccented lead-in tone (a lower pitch than
    /// the normal beat; see `ClickSoundFactory.pickupSpec`), used only for the one-time count-in beats
    /// before the first downbeat. Appended (index 5) so the strong/normal/weak/medium/muted indices the
    /// accuracy tests depend on are byte-for-byte unchanged, and the pickup is never the strong accent.
    case pickup = 5
}
