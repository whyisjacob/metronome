import SwiftUI

/// Quick-access to the last few unique settings, as a horizontal row of chips. Tapping a chip loads
/// that configuration (restoring its stored BPM). Card-less content — it lives inside the "Recents"
/// section of the unified Settings screen; when empty it shows a short explanatory note instead.
struct RecentsBar: View {
    @ObservedObject var recents: RecentsStore
    let onSelect: (MetronomeConfiguration) -> Void

    var body: some View {
        if recents.recents.isEmpty {
            Text("Play a few different settings and they show up here for one-tap recall.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents.recents) { item in
                        Button(action: { onSelect(item.config) }) {
                            chip(for: item.config)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(for config: MetronomeConfiguration) -> some View {
        VStack(spacing: 3) {
            Text(config.timeSignature.displayString)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text("\(Int(config.bpm.rounded())) · \(config.subdivision.symbol)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Text(config.sound.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minWidth: 72)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }
}
