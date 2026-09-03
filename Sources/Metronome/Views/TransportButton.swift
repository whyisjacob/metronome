import SwiftUI

/// The large start/stop control.
struct TransportButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                Text(isPlaying ? "Stop" : "Start")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isPlaying ? Theme.stop : Theme.start)
            )
        }
        .accessibilityLabel(isPlaying ? "Stop metronome" : "Start metronome")
    }
}
