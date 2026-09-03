import SwiftUI

/// Time-signature editor: numerator via a stepper (1–16), denominator via a segmented row {2,4,8,16}.
struct MeterControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        Card("Time signature") {
            HStack {
                Text(viewModel.timeSignature.displayString)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Stepper(
                    "Beats per bar",
                    value: Binding(get: { viewModel.timeSignature.numerator },
                                   set: { viewModel.setNumerator($0) }),
                    in: TimeSignature.numeratorRange
                )
                .labelsHidden()
            }

            HStack(spacing: 8) {
                ForEach(TimeSignature.allowedDenominators, id: \.self) { denom in
                    Button(action: { viewModel.setDenominator(denom) }) {
                        Text("\(denom)")
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.timeSignature.denominator == denom))
                }
            }
        }
    }
}
