# Metronome

An accuracy-first musician's metronome for iOS. v1 is a single, excellent, **sample-accurate**
metronome. The whole point is timing that does not drift — the click grid is derived from the
audio hardware clock, never from `Timer`/`DispatchQueue`.

## Features (v1)

- **Tempo 30–300 BPM** — large stepper/dial, fine ±1, and **tap tempo** (averages the last taps,
  discards outliers).
- **Transport** — start/stop.
- **Time signature** — numerator 1–16, denominator ∈ {2, 4, 8, 16}.
- **Subdivisions** — quarter, eighth, triplet, sixteenth.
- **Accent pattern** — per-beat accents; downbeat accented by default; tap any beat to toggle.
- **Sounds generated in code** — an enveloped "tock" (accent), "tick" (beat), and a soft
  subdivision click. No audio files required; the sound set is structured so more can be added.
- **Visual beat indicator** — pulses in sync with the audio, stronger on the accent.
- **Background audio** — keeps clicking with the screen locked / app backgrounded, mixes with
  other audio, and keeps the screen awake while playing.

## The accuracy core

Timing lives in a small, UI-independent, testable core (`MetronomeEngine` + `RenderPlan`) so a
future Apple Watch app can reuse it.

- Click *N*'s absolute onset is computed as `round(N × secondsPerTick × sampleRate)` — a **closed
  form**, never an accumulation of floats, so cumulative drift is exactly zero.
- Rendering uses an **`AVAudioSourceNode`** whose render callback writes click samples at exact
  frame offsets within each audio block (see `Sources/Metronome/Engine/MetronomeEngine.swift` for
  the rationale vs. `AVAudioPlayerNode.scheduleBuffer`). The audio hardware clock determines the
  actual sounding time; a coarse loop only feeds it.

## Building — requires a Mac or macOS CI

This project is **authored on Windows but cannot be built there** (no Xcode). The `.xcodeproj` is
generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonic/xcodegen):

```sh
brew install xcodegen
cd metronome
xcodegen generate            # creates Metronome.xcodeproj (git-ignored)
open Metronome.xcodeproj
```

Or from the command line:

```sh
xcodebuild -scheme Metronome \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

- **Minimum iOS target:** 17.0
- **Language:** Swift 5.9+, SwiftUI
- **Bundle id:** `app.metronome.mobile`

## Running the tests

The accuracy tests are **headless and deterministic** — they render clicks with AVAudioEngine's
offline manual-rendering mode and assert every onset lands on the ideal sample grid with zero
drift. No device required.

```sh
xcodebuild -scheme Metronome \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

CI runs exactly this on every push — see [`.github/workflows/ios.yml`](.github/workflows/ios.yml).

## Roadmap

See [ROADMAP.md](ROADMAP.md). The headline post-v1 feature is a **Song Builder / tempo-map**
(time signature *and* tempo changing mid-piece, auto-advancing bar-by-bar) — deferred so the
timing engine lands first, since everything else builds on it.
