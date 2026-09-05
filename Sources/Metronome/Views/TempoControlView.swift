import SwiftUI

/// Big BPM readout, coarse slider, fine ±1 nudges, and tap tempo.
struct TempoControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(viewModel.bpm.rounded()))")
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
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

            HStack(spacing: 12) {
                nudge("−1", -1)
                Button(action: { viewModel.tap() }) {
                    Text("TAP")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(PillButtonStyle())
                nudge("+1", +1)
            }
        }
    }

    private func nudge(_ label: String, _ delta: Double) -> some View {
        Button(action: { viewModel.nudgeBPM(delta) }) {
            Text(label)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .frame(width: 74, height: 50)
        }
        .buttonStyle(PillButtonStyle())
    }
}
