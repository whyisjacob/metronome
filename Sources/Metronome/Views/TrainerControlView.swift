import SwiftUI

/// The gap-click trainer panel — a practice tool that silences beats so the musician has to hold time
/// through the gaps. A master toggle keeps the card to a single line when off; the mode picker and its
/// controls appear only once it is enabled. The muting rides the sample-accurate schedule: the count and
/// the beat light keep advancing through every gap.
struct TrainerControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private var trainer: GapTrainer { viewModel.trainer }

    var body: some View {
        Card("Gap-click trainer") {
            Toggle(isOn: Binding(get: { trainer.isEnabled },
                                 set: { viewModel.setTrainerEnabled($0) })) {
                Text("Silence beats to practise internal time")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(Theme.start)

            if trainer.isEnabled {
                modePicker
                if trainer.mode == .random { randomControls } else { barsControls }

                Toggle(isOn: Binding(get: { trainer.keepDownbeat },
                                     set: { viewModel.setTrainerKeepDownbeat($0) })) {
                    Text("Keep a soft downbeat")
                        .font(.system(size: 15, weight: .semibold))
                }
                .tint(Theme.start)

                rampSection

                HStack {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if trainer.mode == .random {
                        Spacer(minLength: 8)
                        Button(action: { viewModel.reshuffleTrainer() }) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 44, height: 34)
                        }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityLabel("Reshuffle random pattern")
                    }
                }
            } else {
                Text("Mutes a share of beats — randomly, or in whole bars — while the count and beat light keep going, so you learn to stay steady through the silence.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(GapTrainer.Mode.allCases) { mode in
                Button(action: { viewModel.setTrainerMode(mode) }) {
                    Text(mode.displayName)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(SelectableStyle(isOn: trainer.mode == mode))
            }
        }
    }

    private var randomControls: some View {
        TrainerStepperRow(title: "Muted", value: trainer.mutePercent, suffix: "%",
                          range: 0...100, step: 5,
                          onChange: { viewModel.setTrainerMutePercent($0) })
    }

    private var barsControls: some View {
        VStack(spacing: 8) {
            TrainerStepperRow(title: "Bars on", value: trainer.barsOn, suffix: "",
                              range: 1...16, step: 1, onChange: { viewModel.setTrainerBarsOn($0) })
            TrainerStepperRow(title: "Bars off", value: trainer.barsOff, suffix: "",
                              range: 1...16, step: 1, onChange: { viewModel.setTrainerBarsOff($0) })
        }
    }

    private var rampSection: some View {
        VStack(spacing: 8) {
            Toggle(isOn: Binding(get: { trainer.rampEnabled },
                                 set: { viewModel.setTrainerRampEnabled($0) })) {
                Text("Ramp difficulty over time")
                    .font(.system(size: 15, weight: .semibold))
            }
            .tint(Theme.start)

            if trainer.rampEnabled {
                TrainerStepperRow(title: "Over", value: trainer.rampBars, suffix: " bars",
                                  range: 1...64, step: 1, onChange: { viewModel.setTrainerRampBars($0) })
                if trainer.mode == .random {
                    TrainerStepperRow(title: "Up to", value: trainer.rampMutePercentPeak, suffix: "%",
                                      range: 0...100, step: 5,
                                      onChange: { viewModel.setTrainerRampMutePercentPeak($0) })
                } else {
                    TrainerStepperRow(title: "Off up to", value: trainer.rampBarsOffPeak, suffix: "",
                                      range: 1...16, step: 1,
                                      onChange: { viewModel.setTrainerRampBarsOffPeak($0) })
                }
            }
        }
    }

    private var caption: String {
        switch trainer.mode {
        case .random:
            return trainer.rampEnabled
                ? "Randomly mutes beats, rising from \(trainer.mutePercent)% to \(trainer.rampMutePercentPeak)% over \(trainer.rampBars) bars."
                : "Randomly mutes \(trainer.mutePercent)% of beats, unpredictably."
        case .barsOnOff:
            return trainer.rampEnabled
                ? "Plays \(barLabel(trainer.barsOn)), then a silent stretch that grows to \(trainer.rampBarsOffPeak) bars."
                : "Plays \(barLabel(trainer.barsOn)), then silences \(barLabel(trainer.barsOff))."
        }
    }

    private func barLabel(_ n: Int) -> String { n == 1 ? "1 bar" : "\(n) bars" }
}

/// A compact −/value/+ stepper row matching the app's pill styling, used for the trainer's numeric knobs.
private struct TrainerStepperRow: View {
    let title: String
    let value: Int
    let suffix: String
    let range: ClosedRange<Int>
    let step: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(action: { onChange(max(range.lowerBound, value - step)) }) {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Decrease \(title)")

            Text("\(value)\(suffix)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(minWidth: 56)
                .monospacedDigit()

            Button(action: { onChange(min(range.upperBound, value + step)) }) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Increase \(title)")
        }
    }
}
