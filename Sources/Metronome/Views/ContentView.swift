import SwiftUI
import Combine

/// The main metronome screen: a clean primary flow — the chosen visual indicator, tempo, a prominent
/// Start, and the core controls (meter, subdivision, sound). Secondary options (visual style, border
/// flash, accents, voice) live behind the settings button; "Save as Song" turns the current settings
/// into a new song and opens the editor.
struct ContentView: View {
    @ObservedObject var viewModel: MetronomeViewModel
    @ObservedObject var recents: RecentsStore
    @ObservedObject var settings: VisualSettingsStore
    @ObservedObject var store: SongStore

    /// Display-rate ticker that refreshes the visual beat indicator. This is purely cosmetic — click
    /// timing is sample-accurate in the audio engine and never depends on this timer.
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var showSettings = false
    @State private var songDraft: Song?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    header

                    BeatVisualView(style: settings.indicatorStyle, state: viewModel.visualState)
                        .frame(height: 250)
                        .frame(maxWidth: .infinity)

                    TempoControlView(viewModel: viewModel)

                    // Start/Stop sits high — right under the tempo readout — so it's prominent and within
                    // easy one-handed reach, not buried at the bottom of the scroll.
                    TransportButton(isPlaying: viewModel.isPlaying) {
                        viewModel.toggle()
                    }

                    RecentsBar(recents: recents) { viewModel.load($0) }

                    MeterControlView(viewModel: viewModel)
                    SubdivisionControlView(viewModel: viewModel)
                    SoundControlView(viewModel: viewModel)
                    TrainerControlView(viewModel: viewModel)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }

            // Screen-border flash: an overlay above the scroll content, below no interactive control
            // (it never intercepts touches). Independent of the chosen indicator.
            BorderFlashOverlay(flashID: viewModel.flashID,
                               isOnBeat: viewModel.isOnBeat,
                               accentLevel: viewModel.activeAccent,
                               enabled: settings.borderFlashEnabled,
                               accentColor: settings.accentFlashColor,
                               normalColor: settings.normalFlashColor)
        }
        .foregroundStyle(Theme.textPrimary)
        .onReceive(ticker) { _ in viewModel.pollPulse() }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $songDraft) { song in
            SongBuilderView(song: song, store: store, settings: settings)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack {
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Settings")

            Spacer()

            Text("MAELZEL")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .tracking(4)
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button(action: saveAsSong) {
                Image(systemName: "bookmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("Save as song")
        }
        .padding(.top, 4)
    }

    /// Creates a song from the current settings (as its first section), saves it to the library, and
    /// opens the editor so it can be named and grown into a full tempo-map.
    private func saveAsSong() {
        let song = Song(fromCurrentSettings: viewModel.config)
        store.upsert(song)
        songDraft = song
    }
}

#Preview {
    ContentView(viewModel: MetronomeViewModel(),
                recents: RecentsStore(),
                settings: VisualSettingsStore(),
                store: SongStore())
        .preferredColorScheme(.dark)
}
