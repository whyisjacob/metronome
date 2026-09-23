# Maelzel release review — 2026-09-23

## Assessment

The project has a substantial sample-clock timing engine, offline accuracy tests, song persistence
and an existing signed TestFlight pipeline. The core screen in the existing simulator captures has
a clear tempo readout and prominent Start control. A redesign is not needed for this release.
This review focused on failure handling and release validation. It is not a physical-device listening
test or a complete accessibility audit.

## Changes

- Audio startup failures now stop the transport and show a recovery message instead of falsely
  showing a song as playing. Start, replay, resume, section seeks and live tempo rebuilds use the
  same failure handler. Seek errors propagate from the engine.
- Song imports require a sections array. A malformed wrapped export cannot fall through and become
  an empty song. Valid legacy JSON, empty drafts and forward-compatible wrapped songs still import.
- Both import entry points surface invalid files. Open-in imports respect the library recovery state.
- Tempo slider and adjustment controls have explicit VoiceOver labels.
- TestFlight depends on successful build, resource validation and unit/accuracy tests for its selected
  revision. Failed validation blocks upload. The test result bundle is retained for diagnosis.
- A portable preflight checks the 1024px opaque RGB icon, all 37 mono voice clips, and privacy manifest.
- TestFlight fails early if the installed iOS SDK is older than 26.

## Evidence

- Local resource preflight: passed (1 icon, 37 voice clips, privacy manifest).
- Workflow YAML parsing and `git diff --check`: passed.
- New regressions cover unrelated JSON, malformed wrappers, valid legacy/empty song imports,
  audio failure state and successful retry.
- macOS compilation and XCTest: **276 tests passed, zero failures**, using Xcode 26.6 on source
  revision `d27135f`. [Successful build and test run](https://github.com/whyisjacob/metronome/actions/runs/35887401200).
- Fresh simulator screenshots: **not verified**. The
  [capture attempt](https://github.com/whyisjacob/metronome/actions/runs/35887210311) stalled during
  simulator boot before capturing screens and was cancelled. The workflow now bounds startup to
  10 minutes, bounds the entire job to 30 minutes, and stops on boot-status failures. Re-run on a
  healthy macOS runner before using new store images.
- Source/project review found no network or analytics dependency in the shipping target. The privacy
  manifest declares no collection or tracking; UserDefaults reason CA92.1 and
  `ITSAppUsesNonExemptEncryption: false` are present. Smart Import camera/photo code is excluded.

Apple's current [SDK submission minimum](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
requires Xcode 26 or later and iOS SDK 26 or later. Supporting iOS 17 devices is a separate deployment
target setting and remains unchanged.

## Before public release

1. Merge the reviewed branch only after its macOS tests pass.
2. Run the manual TestFlight workflow on the merged revision. Confirm the uploaded build finishes
   processing in App Store Connect. This review does not upload, distribute or submit a build.
3. On a real iPhone, check Start/Stop, song pause/resume, section skip, voice, silent practice,
   screen locking, phone/Siri interruptions, Bluetooth/headphone disconnects and recovery. Listen for
   missed/doubled beats at 30 and 300 BPM. Simulator accuracy tests cannot establish route latency
   or real-device interruption behavior.
4. Verify song save/relaunch, export/import through Files/AirDrop, and one multi-section tempo map.
5. Check VoiceOver, large text and the smallest supported iPhone. Existing screenshot tests are
   best-effort navigation captures, not assertions that every screen works.
6. Capture and inspect fresh App Store screenshots. Existing submission notes report a status-bar
   collision on the meter capture; do not assume old marketing exports include the capture fix.
   Local marketing changes predate this review and are left untouched.
7. Confirm actual public support and privacy-policy URLs in App Store Connect. The local submission
   draft still contains placeholders; no live URL or account metadata was verified in this review.
8. Confirm price, age-rating questionnaire, review contact, territories and selected build in App Store
   Connect. Use the existing submission draft as copy, not as proof these fields are complete.

## Release command

After the preceding checks, manually dispatch **TestFlight upload** on the reviewed revision:

```sh
gh workflow run testflight.yml -R whyisjacob/metronome --ref main
```

The workflow is manual-only and does not automatically release to the public App Store.
