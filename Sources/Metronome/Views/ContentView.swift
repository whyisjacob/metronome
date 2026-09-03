import SwiftUI
import Combine

struct ContentView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    /// Display-rate ticker that refreshes the visual beat indicator. This is purely cosmetic — click
    /// timing is sample-accurate in the audio engine and never depends on this timer.
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Text("METRONOME")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .tracking(4)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)

                    BeatIndicatorView(
                        beatCount: viewModel.timeSignature.numerator,
                        activeBeat: viewModel.activeBeat,
                        accents: viewModel.accents,
                        accent: viewModel.activeAccent,
                        flashID: viewModel.flashID,
                        isPlaying: viewModel.isPlaying
                    )

                    TempoControlView(viewModel: viewModel)

                    MeterControlView(viewModel: viewModel)
                    SubdivisionControlView(viewModel: viewModel)
                    AccentRowView(viewModel: viewModel)

                    TransportButton(isPlaying: viewModel.isPlaying) {
                        viewModel.toggle()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .onReceive(ticker) { _ in viewModel.pollPulse() }
    }
}

#Preview {
    ContentView(viewModel: MetronomeViewModel())
        .preferredColorScheme(.dark)
}
