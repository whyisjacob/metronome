# Maelzel

An accuracy-first musician's metronome and song practice app for iPhone (iOS 17+).
The click grid is derived from the
audio hardware clock, never from `Timer`/`DispatchQueue`.

## Features (v1)

- **Tempo 30–300 BPM** — large stepper/dial, fine ±1, and **tap tempo** (averages the last taps,
  discards outliers).
- **Transport** — start/stop, plus pause/resume and section navigation for songs.
- **Time signature** — numerator 1–32, with simple, compound and odd meters.
- **Subdivisions** — quarter, eighth, triplet, sixteenth, quintuplet, sextuplet, septuplet and 32nd.
- **Accent pattern** — per-beat accents; downbeat accented by default; tap any beat to toggle.
- **Sounds generated in code** — an enveloped "tock" (accent), "tick" (beat), and a soft
  subdivision click, plus bundled spoken counting samples.
- **Visual beat indicator** — pulses in sync with the audio, stronger on the accent.
- **Background audio** — keeps clicking with the screen locked / app backgrounded, mixes with
  other audio, and keeps the screen awake while playing.
- **Song builder** — saved tempo maps, section repeats, pickup beats, voice overrides, master tempo scaling,
  JSON / `.maelzelsong` sharing and import, and local backup recovery.
- **Practice controls** — swing, rhythm cells, gap trainer, count-in, recent settings and independent
  click/voice/visual output channels.
- **Visuals** — ball, dots, counter, ring and optional border flash.

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

## Release preparation

Run `python tools/release_preflight.py` on Windows or macOS to validate bundled voice samples,
the app icon and privacy manifest. This does not replace compilation or simulator/device tests.

Every push runs the iOS build and unit/accuracy suite on macOS. The manual TestFlight workflow
also runs that suite on the selected revision and cannot upload unless it passes. Test results
are retained as an `accuracy-test-results` artifact. TestFlight additionally checks the installed
iOS SDK meets the current submission minimum.

See [RELEASE-READINESS.md](RELEASE-READINESS.md) for the evaluation, validation evidence and remaining
submission steps. Photo Smart Import remains excluded. The Apple Watch companion supports automatic
paired-device sync, local vibration/spoken counting, and minimal playback controls. See
[WATCH-COMPANION.md](WATCH-COMPANION.md) for setup, runtime limits, and device acceptance checks.
