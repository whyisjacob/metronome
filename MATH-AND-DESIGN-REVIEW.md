# Timing and interface review

## Timing model

The BPM value counts the app's main pulse: the denominator note in simple meters and the
dotted quarter in compound eighth-note meters (6/8, 9/8, 12/8, and larger multiples of three).
At BPM `b`, sample rate `r`, and `q` subdivisions per main pulse, straight click `n` belongs at
`round(n × 60 × r / (b × q))`. There is no repeated addition of rounded tick lengths.
Quantization to a hardware sample is unavoidable: the ideal nearest-sample error is at most
half a sample, or approximately 11.34 microseconds at 44.1 kHz.

Swing delays the odd member of an eighth/sixteenth pair. Full swing divides the pair 2:1,
while its start and end stay on the original grid. Other subdivision families remain straight.
Pickup timing retains the existing shifted-grid origin: subtracting two quantized positions
can yield up to one sample of fixed phase error, without accumulating per-tick drift.

## Corrections

**Song boundaries previously accumulated quantization error.** The old rule summed separately
rounded section durations and added separately rounded local tick positions. An example of 1,000
one-bar 4/4 sections alternating 137 and 149 BPM at 44.1 kHz ends approximately 15.75 samples early.
The corrected plan retains fractional section origins, uses compensated summation for durations,
and rounds only each final absolute onset. Swing also retains its fractional position until then.

The existing song test oracles encoded the old rounding rule. They now sum continuous durations
before quantizing. Additional integer-rational tests do not depend on the production frame helpers.

**Displayed song durations could disagree with scaled playback.** Playback rounds each scaled BPM
and clamps it to 30–300. Dividing the original duration by the requested scale ignored those rules.
The duration now follows the effective playback configuration. For example, four beats at 30 BPM
with a 50% scale still last eight seconds because the effective tempo remains 30 BPM.

## Validation added

- 107,520 straight-grid onset checks: seven tempos (30, 59, 60, 97, 137, 299, 300), all 32 supported
  numerators, four denominators, eight subdivisions, three sample rates (44.1/48/96 kHz), and five
  tick positions extending beyond one million ticks. Expectations use integer rational arithmetic.
- Exact rational full-swing checks for eighths and sixteenths at 44.1/48 kHz.
- Every click across 1,000 alternating tempo sections compared with an exact rational timeline
  at all three sample rates.
- 80 fractional section boundaries rendered through the actual AVAudioEngine callback, with
  click onsets detected in PCM rather than inferred from SongPlan.
- Duration checks for low/high tempo clamps and rounded scaled BPM.
- Existing offline rendering, pickup, mute, groove, voice and live-change regression tests retained.

**Results:** all 281 unit/accuracy tests passed on Xcode 26.6 for app-source revision `6f5828d`.
The separate UI test passed and produced nine iPhone 17 Pro captures; all four style screens and
the style selector were visually inspected. [Math/audio results](https://github.com/whyisjacob/metronome/actions/runs/35889290043)
and [UI results and captures](https://github.com/whyisjacob/metronome/actions/runs/35889284166).

These checks validate the
digital timeline, not physical output latency, hardware clock calibration, Bluetooth delay or
real-device audio interruption handling.

## Design direction

The old interface gave much of the first screen to a glowing disc, heavy rounded numbers and
highly saturated transport colors. Repeated uppercase headings and nested outlines made ordinary
controls compete for attention.

The revised interface uses neutral surfaces, restrained warm accents, standard system type,
smaller corner radii and fewer outlines. The header stays outside the scrollable controls.
The tempo and transport remain prominent. Pulse animations lose their glow, respect Reduce Motion,
and use cancellable resets instead of accumulating delayed callbacks.

All visual options remain available:

| Style | Intended use |
|---|---|
| Dots | Compact default, easy to glance at while reading music |
| Ball | A clear pulse with a beat number |
| Counter | Large numbers for seeing the count at a distance |
| Ring | Position within the measure and subdivision progress |
| Border flash | Optional peripheral cue, with the existing selectable colors |

Existing saved style preferences remain unchanged. A UI regression test selects all four styles
through Settings and retains screenshots; unavailable controls fail the test rather than being skipped.
