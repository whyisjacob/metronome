import SwiftUI

/// App root: a two-tab shell. The single-tempo metronome, and the Songs library (a tempo-map laid out as
/// a sequence of sections, played with the same sample-accurate engine). Visual preferences are shared
/// across both tabs.
struct RootView: View {
    @StateObject private var metronome: MetronomeViewModel
    @StateObject private var songStore = SongStore()
    @StateObject private var recentsStore: RecentsStore
    @StateObject private var settings = VisualSettingsStore()

    init() {
        // One shared RecentsStore: the view model registers changes into it, the metronome screen
        // observes it for the quick-access row.
        let recents = RecentsStore()
        _recentsStore = StateObject(wrappedValue: recents)
        _metronome = StateObject(wrappedValue: MetronomeViewModel(recents: recents))
    }

    var body: some View {
        TabView {
            ContentView(viewModel: metronome, recents: recentsStore, settings: settings, store: songStore)
                .tabItem { Label("Metronome", systemImage: "metronome") }

            SongLibraryView(store: songStore, settings: settings)
                .tabItem { Label("Songs", systemImage: "music.note.list") }
        }
        .tint(Theme.accentNormal)
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
