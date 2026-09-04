import SwiftUI

/// One cell per beat in the bar; tapping a cell **cycles** its accent: Accent → Medium → Normal → Muted
/// → Accent. The colour and label reflect the state (strong/medium accents glow, muted reads dim). At
/// least one accent is always kept (enforced by the configuration).
struct AccentRowView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private let columns = [GridItem(.adaptive(minimum: 48), spacing: 8)]

    var body: some View {
        Card("Accents") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(viewModel.accents.indices), id: \.self) { index in
                    Button(action: { viewModel.cycleAccent(index) }) {
                        VStack(spacing: 3) {
                            Text("\(index + 1)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text(viewModel.accents[index].shortLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .textCase(.uppercase)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(BeatAccentCellStyle(accent: viewModel.accents[index]))
                    .accessibilityLabel("Beat \(index + 1), \(viewModel.accents[index].shortLabel)")
                }
            }
            Text("Tap a beat to cycle: Accent → Medium → Normal → Muted.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
