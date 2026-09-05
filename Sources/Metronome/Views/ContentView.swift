import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// The main metronome screen — the absolute base only: the beat visual, the tempo (readout, slider, ±1,
/// tap), Start/Stop, and the current time signature + subdivision (both changed constantly). *Everything*
/// else — sound, voice, accents, visuals, border flash, the gap trainer, recents — lives behind the
/// settings button in one unified, collapsible Settings screen, so nothing is scattered. The bookmark
/// button saves the current settings as a Song, with an explicit name prompt and a clear confirmation.
struct ContentView: View {
    @ObservedObject var viewModel: MetronomeViewModel
    @ObservedObject var recents: RecentsStore
    @ObservedObject var settings: VisualSettingsStore
    @ObservedObject var soundSettings: SoundSettingsStore
    @ObservedObject var store: SongStore

    /// Display-rate ticker that refreshes the visual beat indicator. This is purely cosmetic — click
    /// timing is sample-accurate in the audio engine and never depends on this timer.
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var showSettings = false

    // Save-as-Song: an explicit, confirmed flow. The bookmark opens a name prompt; only "Save" persists
    // (so cancelling leaves nothing behind), and a brief banner confirms the song reached the library.
    @State private var showSaveSongDialog = false
    @State private var newSongName = ""
    @State private var savedSongName: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header

                    // The visual channel can be muted (pure-audio practice); it then shows the idle
                    // indicator while the engine keeps the beat, so re-enabling it is instant and in-phase.
                    BeatVisualView(style: settings.indicatorStyle,
                                   state: viewModel.channels.visual
                                        ? viewModel.visualState
                                        : BeatVisualState.idle(beatsPerMeasure: viewModel.beatsPerBar,
                                                               ticksPerBeat: viewModel.ticksPerBeat,
                                                               accents: viewModel.accents))
                        .frame(height: 250)
                        .frame(maxWidth: .infinity)

                    // Silent-practice: a prominent mute + Full / Count / Flash presets, on the main screen
                    // so a musician can switch mid-practice. Common to single-tempo AND song mode.
                    MuteControlView(viewModel: viewModel)

                    if let song = viewModel.activeSong {
                        // Song mode: the SAME screen becomes the song's display (now-playing strip +
                        // section progress + transport + exit). No separate player.
                        SongNowPlayingView(viewModel: viewModel, song: song)
                    } else {
                        TempoControlView(viewModel: viewModel)

                        // Start/Stop sits high — right under the tempo readout — so it's prominent and
                        // within easy one-handed reach, not buried at the bottom of the scroll.
                        TransportButton(isPlaying: viewModel.isPlaying) {
                            viewModel.toggle()
                        }

                        // Meter + subdivision stay on the main screen: they're changed constantly, and
                        // they're the "current time signature + subdivision" readout.
                        MeterControlView(viewModel: viewModel)
                        SubdivisionControlView(viewModel: viewModel)

                        // Count-in / pickup: a primary control (moved out of Settings), so a lead-in sits
                        // with the base controls (CountInControlView is card-less — wrap it here).
                        Card("Count-in") {
                            CountInControlView(viewModel: viewModel)
                        }

                        // Sound is a base control too — reached often — so the picker lives on the main
                        // screen (SoundControlView is card-less, so wrap it in the shared titled card here).
                        Card("Sound") {
                            SoundControlView(viewModel: viewModel)
                        }

                        // A subtle pointer to everything else, one tap away in the unified Settings.
                        settingsTag
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }

            // Screen-border flash: an overlay above the scroll content, below no interactive control
            // (it never intercepts touches). Independent of the chosen indicator.
            BorderFlashOverlay(flashID: viewModel.flashID,
                               isOnBeat: viewModel.isOnBeat,
                               accentLevel: viewModel.activeAccent,
                               // The border flash is part of the visual channel — muting Visual stops it too.
                               enabled: settings.borderFlashEnabled && viewModel.channels.visual,
                               accentColor: settings.accentFlashColor,
                               normalColor: settings.normalFlashColor)

            savedBanner
        }
        .foregroundStyle(Theme.textPrimary)
        .onReceive(ticker) { _ in viewModel.pollPulse() }
        // Keep the screen awake while anything is playing (single-tempo or a song). Lives here, in the
        // view, so the view-model stays UIKit-free and headless-testable.
        .onChange(of: viewModel.isPlaying) { _, playing in
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = playing
            #endif
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, viewModel: viewModel,
                         soundSettings: soundSettings, recents: recents, store: store)
                .preferredColorScheme(.dark)
        }
        .alert("Save as Song", isPresented: $showSaveSongDialog) {
            TextField("Song name", text: $newSongName)
            Button("Save", action: saveAsSong)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the current tempo, meter, subdivision and accents as a new song in your library. You can add more sections later in the Songs tab.")
        }
    }

    /// A subtle, tappable tag at the bottom of the main screen: keeps the screen minimal while making
    /// clear there's much more (voice, groove, accents, visuals, the trainer, the section builder…) one
    /// tap away in the unified Settings.
    private var settingsTag: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 6) {
                Text("Many more options in Settings")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Open Settings for more options")
    }

    private var header: some View {
        // Title centred via a ZStack so the leading (settings) and trailing (save) controls don't pull it
        // off-centre. (The experimental photo Smart Import is intentionally not surfaced here — see below.)
        ZStack {
            Text("MAELZEL")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .tracking(4)
                .foregroundStyle(Theme.textSecondary)

            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Settings")

                Spacer()

                // Save-as-Song captures the single-tempo settings; hide it while a song is playing (there
                // are no single-tempo settings to save then).
                if viewModel.activeSong == nil {
                    Button(action: presentSaveSong) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Save as song")
                }
            }
        }
        .padding(.top, 4)
    }

    /// A brief, self-dismissing confirmation that the song was saved — so the user is never unsure whether
    /// or how their settings persisted to the library.
    @ViewBuilder private var savedBanner: some View {
        if let name = savedSongName {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.start)
                    Text("Saved “\(name)” to Songs")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
                .padding(.bottom, 28)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// Opens the name prompt, pre-filled with a sensible default (tempo + meter) so Save works in one tap.
    private func presentSaveSong() {
        newSongName = "\(Int(viewModel.bpm.rounded())) BPM · \(viewModel.timeSignature.displayString)"
        showSaveSongDialog = true
    }

    /// Creates a song from the current settings, saves it to the library, and shows a confirmation. Only
    /// reached from the prompt's explicit "Save", so cancelling never leaves an orphaned song behind.
    private func saveAsSong() {
        let trimmed = newSongName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "New Song" : trimmed
        let song = Song(fromCurrentSettings: viewModel.config, name: name)
        store.upsert(song)
        withAnimation(.easeInOut(duration: 0.25)) { savedSongName = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.3)) { savedSongName = nil }
        }
    }
}

#Preview {
    ContentView(viewModel: MetronomeViewModel(),
                recents: RecentsStore(),
                settings: VisualSettingsStore(),
                soundSettings: SoundSettingsStore(),
                store: SongStore())
        .preferredColorScheme(.dark)
}
