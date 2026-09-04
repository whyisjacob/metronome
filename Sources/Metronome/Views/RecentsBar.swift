import SwiftUI

/// Quick-access to the last few unique settings, as a horizontal row of chips. Tapping a chip loads
/// that configuration (restoring its stored BPM). Renders nothing when there are no recents.
struct RecentsBar: View {
    @ObservedObject var recents: RecentsStore
    let onSelect: (MetronomeConfiguration) -> Void

    var body: some View {
        if !recents.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENTS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)

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
