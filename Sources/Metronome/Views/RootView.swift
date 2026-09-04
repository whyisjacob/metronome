import SwiftUI

/// App root: a two-tab shell. The original single-tempo metronome, and the v2 Song Builder that lays
/// out a piece as a sequence of tempo/meter/subdivision changes and plays it with the same
/// sample-accurate engine.
struct RootView: View {
    @StateObject private var metronome = MetronomeViewModel()
    @StateObject private var songStore = SongStore()

    var body: some View {
        TabView {
            ContentView(viewModel: metronome)
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
