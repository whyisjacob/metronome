import Foundation

// "Save as Song" building blocks. These are pure value-type conveniences that turn a live single-tempo
// `MetronomeConfiguration` into a one-section `Song`; they add no timing behaviour and deliberately live
// outside the Engine group so the verified engine files stay untouched.

extension SongSection {
    /// A section that reproduces a live `MetronomeConfiguration` — same tempo, meter, subdivision and
    /// accent pattern — as a single bar played once. The starting point for "Save as Song".
    ///
    /// (A section carries no sound: song mode always uses the classic click, matching the engine.)
    init(from config: MetronomeConfiguration, name: String = "Section 1") {
        self.init(name: name,
                  tempoBPM: config.bpm,
                  timeSignature: config.timeSignature,
                  subdivision: config.subdivision,
                  accentPattern: config.accents,
                  bars: 1,
                  repeatCount: 1)
    }
}

extension Song {
    /// A brand-new song whose first section is the current metronome settings, so a song can be grown
    /// from exactly what you are already playing. Used by the metronome screen's "Save as Song" action.
    init(fromCurrentSettings config: MetronomeConfiguration, name: String = "New Song") {
        self.init(name: name, sections: [SongSection(from: config, name: "Section 1")])
    }
}
