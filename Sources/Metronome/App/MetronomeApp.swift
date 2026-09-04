import SwiftUI

@main
struct MetronomeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)   // dark, high-contrast, stage-friendly
        }
    }
}
