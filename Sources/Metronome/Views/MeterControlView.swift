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

            // Quick accent groupings for asymmetric meters (e.g. 7/8 as 2+2+3 or 3+2+2). Each sets the
            // downbeat strong and every subsequent group head to a secondary (medium) accent.
            if !groupingPresets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GROUPING")
                        .font(.system(size: 12, weight: .bold)).tracking(1.1)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 8) {
                        ForEach(groupingPresets, id: \.self) { group in
                            Button(action: { viewModel.applyGrouping(group) }) {
                                Text(group.map(String.init).joined(separator: "+"))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(SelectableStyle(isOn: viewModel.accents == Self.groupingAccents(group, beats: viewModel.accents.count)))
                        }
                    }
                }
            }
        }
    }

    /// The grouping presets offered for the current (simple, asymmetric) meter, or none. Compound meters
    /// are auto-grouped into their dotted-quarter beats, so they don't need presets.
    private var groupingPresets: [[Int]] {
        guard !viewModel.timeSignature.isCompound else { return [] }
        switch viewModel.timeSignature.beatsPerBar {
        case 5: return [[2, 3], [3, 2]]
        case 7: return [[2, 2, 3], [3, 2, 2], [2, 3, 2]]
        default: return []
        }
    }

    /// The accent pattern a grouping produces (strong downbeat, medium subsequent group heads), used to
    /// mark the active preset. Mirrors `MetronomeViewModel.applyGrouping`.
    private static func groupingAccents(_ groups: [Int], beats: Int) -> [BeatAccent] {
        var pattern = [BeatAccent](repeating: .normal, count: max(beats, 0))
        guard !pattern.isEmpty else { return pattern }
        pattern[0] = .strong
        var index = 0
        for size in groups where size > 0 {
            if index > 0 && index < pattern.count { pattern[index] = .medium }
            index += size
        }
        return pattern
    }
}
