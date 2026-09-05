import Foundation

// "Save as Song" building blocks (formerly the misleadingly-named `SongDraft.swift` — there is no draft
// system here). These are pure value-type conveniences that turn a live single-tempo
// `MetronomeConfiguration` into a one-section `Song`, plus small section-editing helpers; they add no
// timing behaviour and deliberately live outside the Engine group so the verified engine files stay
// untouched.

extension SongSection {
    /// A section that reproduces a live `MetronomeConfiguration` — same tempo, meter, subdivision, accents
    /// and groove (swing / cell) — as a single bar played once. The starting point for "Save as Song".
    ///
    /// (A section carries no sound: song mode always uses the classic click, matching the engine.)
    init(from config: MetronomeConfiguration, name: String = "Section 1") {
        self.init(name: name,
                  tempoBPM: config.bpm,
                  timeSignature: config.timeSignature,
                  subdivision: config.subdivision,
                  accentPattern: config.accents,
                  bars: 1,
                  repeatCount: 1,
                  swing: config.swing,
                  cell: config.cell)
    }

    /// This section's tempo/meter/subdivision/accents/groove as a `MetronomeConfiguration` — the exact
    /// value type the shared main-screen controls edit. The section editor seeds a `MetronomeViewModel`
    /// from this and reads it back on save, so there is ONE implementation of "set tempo / meter /
    /// subdivision / accents / groove" and editing round-trips through it. `sound` is `.classic` because a
    /// section carries none (song mode always uses the classic click).
    var configuration: MetronomeConfiguration {
        MetronomeConfiguration(bpm: tempoBPM,
                               timeSignature: timeSignature,
                               subdivision: subdivision,
                               accents: accentPattern,
                               sound: .classic,
                               swing: swing,
                               cell: cell)
    }

    /// Rebuilds a section from an edited `MetronomeConfiguration`, keeping this section's identity and its
    /// section-only fields (name, bars, repeats). The inverse of `configuration` — the save side of the
    /// round-trip through the shared controls.
    func updating(from config: MetronomeConfiguration,
                  name: String, bars: Int, repeatCount: Int) -> SongSection {
        SongSection(id: id,
                    name: name,
                    tempoBPM: config.bpm,
                    timeSignature: config.timeSignature,
                    subdivision: config.subdivision,
                    accentPattern: config.accents,
                    bars: bars,
                    repeatCount: repeatCount,
                    swing: config.swing,
                    cell: config.cell)
    }
}

extension Song {
    /// A brand-new song whose first section is the current metronome settings, so a song can be grown
    /// from exactly what you are already playing. Used by the metronome screen's "Save as Song" action.
    init(fromCurrentSettings config: MetronomeConfiguration, name: String = "New Song") {
        self.init(name: name, sections: [SongSection(from: config, name: "Section 1")])
    }

    /// A copy with fresh identity (new song + section `UUID`s) and a "copy" suffix, so it can be upserted
    /// as a distinct library entry that never collides with the original in SwiftUI lists or the store.
    func duplicated() -> Song { copyWithFreshIDs(name: name + " copy") }

    /// A copy with fresh identity but the SAME name — used on import so a shared song is added as a new
    /// library entry rather than silently overwriting an existing one with the same `id`.
    func reidentified() -> Song { copyWithFreshIDs(name: name) }

    /// A copy with the section of the same `id` replaced (a no-op if none matches). The song builder uses
    /// this to commit an in-progress section edit **live** — so an uncommitted edit inside the open section
    /// editor survives a force-quit (autosave picks up each change) — and to restore the pre-edit snapshot
    /// when the user taps Cancel. (P2.6)
    func replacingSection(_ section: SongSection) -> Song {
        guard let i = sections.firstIndex(where: { $0.id == section.id }) else { return self }
        var copy = self
        copy.sections[i] = section
        return copy
    }

    private func copyWithFreshIDs(name newName: String) -> Song {
        Song(id: UUID(),
             name: newName,
             sections: sections.map {
                 SongSection(id: UUID(), name: $0.name, tempoBPM: $0.tempoBPM,
                             timeSignature: $0.timeSignature, subdivision: $0.subdivision,
                             accentPattern: $0.accentPattern, bars: $0.bars, repeatCount: $0.repeatCount,
                             swing: $0.swing, cell: $0.cell)
             },
             tempoScale: tempoScale)
    }
}
