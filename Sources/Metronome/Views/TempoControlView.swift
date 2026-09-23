import SwiftUI

/// Big BPM readout, coarse slider, fine ±1 nudges, and tap tempo.
struct TempoControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(viewModel.bpm.rounded()))")
                    .font(.system(size: 72, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text("BPM")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            Slider(
                value: Binding(get: { viewModel.bpm }, set: { viewModel.setBPM($0) }),
                in: MetronomeConfiguration.tempoRange,
                step: 1
            )
            .tint(Theme.accentNormal)
            .accessibilityLabel("Tempo")
            .accessibilityValue("\(Int(viewModel.bpm.rounded())) beats per minute")

            HStack(spacing: 12) {
                nudge("−1", -1)
                Button(action: { viewModel.tap() }) {
                    Text("Tap tempo")
                        .font(.system(size: 16, weight: .medium, design: .default))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Tap tempo")
                .accessibilityHint("Tap repeatedly in time to set the tempo")
                nudge("+1", +1)
            }
        }
    }

    private func nudge(_ label: String, _ delta: Double) -> some View {
        Button(action: { viewModel.nudgeBPM(delta) }) {
            Text(label)
                .font(.system(size: 22, weight: .bold, design: .default))
                .frame(width: 74, height: 50)
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityLabel(delta < 0 ? "Decrease tempo by one" : "Increase tempo by one")
    }
}
