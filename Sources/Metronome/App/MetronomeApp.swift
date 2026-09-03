import SwiftUI

@main
struct MetronomeApp: App {
    @StateObject private var viewModel = MetronomeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)   // dark, high-contrast, stage-friendly
        }
    }
}
