# Music-theory audit

## Meter and tempo

Open Music Theory defines compound beats as three divisions, including quarter- and sixteenth-note
notated divisions, not only eighth notes. This exposed a real bug: the app treated 6/4 and 9/16 as
necessarily ungrouped. New meters now default to the conventional grouping, and an explicit tempo-beat
selector allows denominator-note counting. Fast 3/x meters can also be counted as one dotted beat.

| Meter | Default BPM unit | Main beats/bar | Native divisions/beat |
|---|---|---:|---:|
| 2/2 | Half note | 2 | 2 |
| 3/4 | Quarter note | 3 | 2 |
| 6/4 | Dotted half | 2 | 3 |
| 6/8 | Dotted quarter | 2 | 3 |
| 9/16 | Dotted eighth | 3 | 3 |
| 12/8 | Dotted quarter | 4 | 3 |
| 7/8 | Eighth note | 7 | 2 |

Source: [Open Music Theory: Compound Meter and Time Signatures](https://viva.pressbooks.pub/openmusictheory/chapter/compound-meters-and-time-signatures/).

BPM always refers to the displayed note value. Selecting another beat unit keeps the numerical BPM;
it intentionally changes the speed in notated note values. It resets subdivisions to the main beat,
resets default accents, and clamps the pickup. It does not promise automatic metric modulation.
Old JSON without a beat-unit field retains its former interpretation, so an existing six-quarter 6/4
song does not suddenly become three times faster. New exports explicitly persist the choice.

## Subdivision, swing and pattern audit

- Straight timing uses 60/BPM seconds per selected beat, divided equally by the click count.
- Simple grids provide 1–8 clicks per beat, including 3-, 5-, 6- and 7-part divisions.
- Grouped grids expose distinct 1-, 3-, 5-, 6-, 7- and 12-part divisions. Native note labels follow
  the denominator: three divisions of a dotted half are quarters, not eighths.
- The selector uses click counts instead of misleading quarter-note glyphs in half-note meters.
- Swing interpolates each pair from 1:1 to 2:1. Main beats and pair boundaries do not move.
  This is a defined practice range, not a claim to reproduce every performer's swing interpretation.
- Pattern labels use beat fractions: 3/4 + 1/4, 1/2 + 1/4 + 1/4, or 1/4 + 1/4 + 1/2.
  These are straight-grid lengths; enabling swing changes the intervals. Patterns require four
  divisions per beat and remain inactive with grouped dotted beats.

## Accents, odd meters and pickups

Accent presets are editable practice defaults, not universal performance instructions. In 5/8 and 7/8,
grouping buttons place secondary accents on the chosen group starts; BPM still counts equal eighths.
The app does not interpret a 2+2+3 grouping as three equally long beats.

The existing partial-bar lead-in is now labelled **Pickup**. It plays the tail of one bar once,
then starts beat 1. It is not a full-measure count-in and does not shorten a song's final measure.
A stale pickup on a one-click bar previously subtracted a whole beat from the time origin; the plan
now tests the effective pickup length, so the first click starts at sample zero.

Counting syllables are one supported convention. Compound three-part divisions use the bundled
“trip/let” syllables; this is a counting aid, not a claim that native compound divisions are tuplets.
At dense tempos some subdivisions click instead of speaking to keep syllables intelligible.

## Verification and limits

MeterInterpretationTests covers explicit beat units, compound /4 and /16 audio onsets, native note
names, denominator counting, optional one-beat 3/x, saved-data migration, song sharing, invalid input,
pickup clamping and the one-click-bar regression. The broad integer-rational timing matrix now includes
compound grouping for every supported denominator. Existing denominator-counting song tests explicitly
select that interpretation instead of incorrectly calling 6/4 simple duple.

The simulator UI test exercises both 6/4 beat-unit choices and captures their visible beat counts.
The style test retains ball, dots, counter and ring.

This is a correctness audit of the supported practice model, not universal coverage of music theory.
Unsupported cases include arbitrary tuplet ratios spanning multiple beats, compound duplets, mixed
unequal conducting beats, simultaneous polyrhythm layers, automatic metric modulation and full-bar
count-ins. Hardware audio latency and interruption recovery still require a real-device check.

Validation: **290 tests passed, zero failures**, on source revision `0e086c2`, including rendered-audio checks.
[macOS/Xcode validation run](https://github.com/whyisjacob/metronome/actions/runs/35891602499).

Final verification on `4ff320d`: [290 unit/audio tests passed](https://github.com/whyisjacob/metronome/actions/runs/35893431303)
and [both simulator UI tests passed](https://github.com/whyisjacob/metronome/actions/runs/35893431362).
Eleven screenshots were captured; the 6/4 dotted-half selector and tempo display were visually inspected.
The first UI attempt passed all four styles but failed to locate the SwiftUI wheel by its container label;
the test now targets the wheel itself and scrolls outside its touch area. App timing code was unchanged.
