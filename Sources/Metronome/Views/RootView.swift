import SwiftUI

/// App root: a two-tab shell. The original single-tempo metronome, and the v2 Song Builder that lays
/// out a piece as a sequence of tempo/meter/subdivision changes and plays it with the same
/// sample-accurate engine.
struct RootView: View {
    @StateObject private var metronome: MetronomeViewModel
    @StateObject private var songStore = SongStore()
    @StateObject private var recentsStore: RecentsStore

    init() {
        // One shared RecentsStore: the view model registers changes into it, the metronome screen
        // observes it for the quick-access row.
        let recents = RecentsStore()
        _recentsStore = StateObject(wrappedValue: recents)
        _metronome = StateObject(wrappedValue: MetronomeViewModel(recents: recents))
    }

    var body: some View {
        TabView {
            ContentView(viewModel: metronome, recents: recentsStore)
                .tabItem { Label("Metronome", systemImage: "metronome") }

            SongLibraryView(store: songStore)
                .tabItem { Label("Songs", systemImage: "music.note.list") }
        }
        .tint(Theme.accentNormal)
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
