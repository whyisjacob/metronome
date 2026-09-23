import SwiftUI

/// The large start/stop control.
struct TransportButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 18, weight: .medium))
                Text(isPlaying ? "Stop" : "Start")
                    .font(.system(size: 18, weight: .semibold, design: .default))
            }
            .foregroundStyle(isPlaying ? Theme.textPrimary : Theme.background)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPlaying ? Theme.surfaceRaised : Theme.start)
            )
        }
        .accessibilityLabel(isPlaying ? "Stop metronome" : "Start metronome")
    }
}
