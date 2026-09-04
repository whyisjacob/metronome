# Roadmap

v1 was metronome-only and accuracy-first (see [README](README.md)). This tracks what has shipped since
and what is queued next. **The verified timing engine (`MetronomeEngine` / `RenderPlan` / `SongPlan` and
the offline-render accuracy tests) is the source of truth for *when* a click sounds and is never bent for
a feature — everything below is built on top of it.**

## Done

- **Song Builder / tempo-map** *(the core differentiator)* — a piece is an ordered list of sections whose
  tempo, meter, subdivision and accents can each change; the engine auto-advances bar-by-bar and
  section-by-section with **zero cumulative drift across boundaries** (`SongPlan`).
- **Songs library + build-from-current** — saved-songs library with add / edit / reorder / delete, a
  clear play flow, and a **"Save as Song"** action that seeds a new song from the current metronome
  settings and opens the editor.
- **Custom & odd meters** — arbitrary numerator up to 32 (5, 7, 11, 13, …) with sensible default accents.
- **Compound meters** — 6/8, 9/8, 12/8 grouped in threes for accenting and Voice counting.
- **32nd-note subdivision** — added alongside quarter / eighth / triplet / sixteenth.
- **Counting Voice + subdivision syllables** — spoken beat numbers plus "e / and / a" / "trip-let"
  subdivision syllables, scheduled sample-accurately like a click.
- **Recents** — the last few unique settings, one tap to restore.
- **Live setting changes / slider fix** — tempo, meter, subdivision and accents can change mid-playback
  with a drift-free re-anchor (no gap, no double-trigger).
- **Selectable visual beat indicators** — Ball / Dots / Counter / Ring, all driven by the engine's
  beat + subdivision state so they stay locked to the audio; the ring/dots/counter reflect subdivisions.
- **Screen-border flash** — an optional edge flash on each beat with user-selectable accent-beat vs
  normal-beat colours, independent of the chosen indicator.

## Queued

In priority order:

1. **On-device photo Smart Import** — snap a photo of a score and prefill a draft with Apple **Vision**
   OCR: detect the **tempo marking** (e.g. `♩ = 120`, "Allegro") and the **time signature**, entirely
   on-device (no network, privacy-friendly). *Stretch:* estimate **bar count**, and detect **mid-piece
   meter changes** to seed a multi-section tempo-map automatically.

2. **Custom built-in PDF sheet-music reader** — a PDFKit, forScore-style reader with tap-zone / half-page
   navigation and **auto page-turns driven by the tempo map**. Preferred over depending on forScore.

3. **forScore integration** — one-way MIDI **Control Change** output to auto-turn forScore pages and cue
   scores from the tempo map. (forScore has no SDK and listens for MIDI CC, not notes; keyboard-shortcut
   emulation is the fallback if CC proves insufficient.)

4. **Apple Watch companion** — Digital Crown to set tempo, transport controls, and a downbeat haptic.
   (watchOS haptics are *not* sample-accurate and degrade at high tempo, so the Watch is a controller +
   coarse pulse, not the timing source of truth.)

5. **Monetization** — a single **$5 one-time unlock** (StoreKit 2 non-consumable). **No subscription,
   no ads.**
