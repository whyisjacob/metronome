import SwiftUI

/// Time-signature editor: an **arbitrary** numerator up to 32 via a stepper (for odd/large meters),
/// quick-pick chips for common ones, and the denominator as a segmented row {2,4,8,16}.
struct MeterControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    /// Fast access to common and odd meters; any other numerator (up to 32) is reachable via the stepper.
    private static let quickNumerators = [2, 3, 4, 5, 6, 7, 9, 11, 13]

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

            // Quick numerators (odd meters included). Arbitrary values up to 32 stay available via the stepper.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 8)], spacing: 8) {
                ForEach(Self.quickNumerators, id: \.self) { n in
                    Button(action: { viewModel.setNumerator(n) }) {
                        Text("\(n)")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.timeSignature.numerator == n))
                }
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
