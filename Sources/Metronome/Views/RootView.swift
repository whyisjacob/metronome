import SwiftUI

/// App root: a two-tab shell over ONE metronome. The Metronome tab is the single transport/display for
/// both the single-tempo click AND song playback — starting a song drives this same screen (there is no
/// separate player). The Songs tab is the library/builder. Visual + sound preferences are shared.
struct RootView: View {
    @StateObject private var metronome: MetronomeViewModel
    @StateObject private var songStore = SongStore()
    @StateObject private var recentsStore: RecentsStore
    @StateObject private var settings = VisualSettingsStore()
    @StateObject private var soundSettings: SoundSettingsStore

    /// 0 = Metronome, 1 = Songs. A binding so playing a song can reveal the Metronome tab automatically.
    @State private var selectedTab = 0

    init() {
        // One shared RecentsStore + SoundSettingsStore, and ONE shared MetronomeViewModel that drives both
        // the single-tempo click and song playback, so there is only ever one engine.
        let recents = RecentsStore()
        let sound = SoundSettingsStore()
        _recentsStore = StateObject(wrappedValue: recents)
        _soundSettings = StateObject(wrappedValue: sound)
        _metronome = StateObject(wrappedValue: MetronomeViewModel(recents: recents, soundSettings: sound))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ContentView(viewModel: metronome, recents: recentsStore, settings: settings,
                        soundSettings: soundSettings, store: songStore)
                .tabItem { Label("Metronome", systemImage: "metronome") }
                .tag(0)

            SongLibraryView(store: songStore, metronome: metronome)
                .tabItem { Label("Songs", systemImage: "music.note.list") }
                .tag(1)
        }
        .tint(Theme.accentNormal)
        // Any `playSong` (from the library, the builder, or the Settings launcher) bumps this nonce; reveal
        // the Metronome tab so the user sees the song playing on the one shared screen.
        .onChange(of: metronome.songLaunchNonce) { _, _ in selectedTab = 0 }
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
