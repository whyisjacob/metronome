import SwiftUI

/// The primary tempo control: a big BPM readout, a roll-to-select number wheel (the prominent way to dial
/// in an exact tempo), plus fine ±1 nudges and tap tempo. The wheel stays in sync with the engine — a
/// nudge, a tap, or a loaded song/recent rolls it to the current BPM — and rolling it updates the tempo
/// live.
struct TempoControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    /// The wheel binds to an integer BPM: rolling it sets the tempo live, and any *other* change to the
    /// tempo (nudge, tap, a loaded song) drives the wheel back to the current value — so control and
    /// engine can never disagree.
    private var rollerSelection: Binding<Int> {
        Binding(get: { Int(viewModel.bpm.rounded()) },
                set: { viewModel.setBPM(Double($0)) })
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(viewModel.bpm.rounded()))")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text("BPM")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            tempoRoller

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

    /// The roll-to-select number wheel — a vertical wheel `Picker` spanning the whole tempo range; the
    /// centred number is the selected BPM. Housed in its own surface so it reads as a distinct control and
    /// reliably captures the vertical roll gesture inside the scrolling screen.
    private var tempoRoller: some View {
        Picker("Tempo", selection: rollerSelection) {
            ForEach(MetronomeConfiguration.selectableTempos, id: \.self) { bpm in
                Text("\(bpm)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tag(bpm)
            }
        }
        .labelsHidden()
        .pickerStyle(.wheel)
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Tempo")
        .accessibilityValue("\(Int(viewModel.bpm.rounded())) BPM")
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
