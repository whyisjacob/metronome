# Maelzel Apple Watch companion

Requires watchOS 10+ and the paired iPhone app. Install the watch app through the iPhone Watch app or TestFlight. Open Maelzel on both devices once; pairing uses WatchConnectivity, with no account or code.

The phone syncs its current metronome settings and selected song. Start on the watch first asks the phone to stop; the watch then plays locally. Stop on either device ends watch playback. The phone does not auto-resume. Songs start from their beginning, including their pickup; this is a handoff, not simultaneous phase-locked playback.

The watch is vibration-only, with no sound selector, spoken counting, speaker output, or audio session. Previous audio preferences are discarded. It shows a large beat number, meter, subdivision, Start/Stop, and ± tempo. A selected song shows its title and Start Song. Song tempo controls adjust the master percentage. Phone changes received during playback apply after Stop.

## Runtime limits

Subdivision follows the phone, including song section changes, swing, and pickups. Muted beats and rhythm cells are respected. Very fast grids may exceed the hardware's ability to produce distinct taps.

- Vibration uses the watch’s haptic engine while the app is active. Lowering the wrist or leaving the app stops vibration; the screen explicitly reports this. No fake workout, silent background audio, or unrelated extended-runtime category is used.
- Keeping the display continuously awake remains unsupported: watchOS controls display sleep. Always On is not an execution entitlement and does not keep haptic timers running. The app explains this limitation in Settings rather than offering a nonfunctional keep-awake switch.
- A live connection is required for starting a handoff and editing synchronized settings. Once playing, losing the phone connection does not change the watch’s beat clock. Stop is local immediately; a token-scoped release is delivered when connectivity returns.
- Haptics follow an absolute local monotonic clock and skip delayed beats instead of bursting. WatchKit controls actual vibration timing; audio accuracy claims do not apply to haptics.
- Large songs above the WatchConnectivity context limit produce a visible sync error.

## Device acceptance checks

1. Install phone/watch build together; launch both and verify automatic sync with no code.
2. Play phone, Start watch: phone must go silent before first watch beat.
3. Stop on watch and phone, rapid Start/Cancel, disconnect/reconnect, and force quit/relaunch each app. No delayed message may start a second player or cancel a newer handoff.
4. Verify 92 BPM, slow/fast tempos, compound 6/8, odd 7/8, pickups, section changes, and replay after completion.
5. Verify vibration with wrist raised and lowered; the UI must accurately report stopped state.
7. Change tempo/meter and confirm phone settings follow; confirm saved song section tempos remain unchanged when adjusting master tempo.

References: https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity and https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)
