import SwiftUI

/// The large start/stop control.
struct TransportButton: View {
    let isPlaying: Bool
    var startTitle = "Start"
    var stopTitle = "Stop"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                Text(isPlaying ? stopTitle : startTitle)
                    .font(.system(size: 28, weight: .bold, design: .default))
            }
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isPlaying ? Theme.stop : Theme.start)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? stopTitle : startTitle)
    }
}
