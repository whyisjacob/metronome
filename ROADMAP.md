# Roadmap

v1 is metronome-only and accuracy-first (see [README](README.md)). Post-v1 work, in priority order:

1. **Song Builder / tempo-map** *(the core differentiator)* — define a piece as an ordered list of
   sections where the time signature **and** tempo can change mid-piece and change again, and the
   metronome auto-advances bar-by-bar through them. Deferred to v2 so the zero-drift engine lands
   and stabilizes first; the engine's tick→frame math already generalizes to a per-section grid.

2. **Apple Watch companion** — Digital Crown to set tempo, transport controls, and a downbeat
   haptic. (Note: watchOS haptics are *not* sample-accurate and degrade at high tempo, so the Watch
   is a controller + coarse pulse, not the timing source of truth.)

3. **Custom built-in PDF sheet-music reader** — a PDFKit, forScore-style reader with tap-zone /
   half-page navigation and **auto page-turns driven by the tempo map**. Preferred over depending on
   forScore.

4. **forScore integration** — one-way MIDI **Control Change** output to auto-turn forScore pages and
   cue scores from the tempo map. (forScore has no SDK and listens for MIDI CC, not notes;
   keyboard-shortcut emulation is the fallback if CC proves insufficient.)

5. **Monetization** — a single **$5 one-time unlock** (StoreKit 2 non-consumable). No subscription,
   no ads.
