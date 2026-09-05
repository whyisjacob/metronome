import SwiftUI

/// Time-signature editor as a **roll-to-select** control: a numerator wheel (1–32, so any simple, odd, or
/// large meter is reachable) beside a denominator wheel (2/4/8/16). Scroll each wheel to dial the meter —
/// e.g. roll to 4/4, 3/4, 6/8, 7/8. Both wheels' option lists are `TimeSignature`'s own validation
/// constants (`numeratorRange`, `allowedDenominators`), so a value you can roll to is always a meter the
/// model accepts and the wheels can never drift out of sync with the engine. Quick accent-grouping presets
/// for asymmetric meters remain below (they shape the accents, not the meter itself).
struct MeterControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    /// Rolling the numerator wheel installs a new meter (keeping the current denominator); the getter pins
    /// the wheel to the current numerator, so the wheel and the engine can never disagree.
    private var numeratorSelection: Binding<Int> {
        Binding(get: { viewModel.timeSignature.numerator },
                set: { viewModel.setNumerator($0) })
    }

    /// Rolling the denominator wheel installs a new meter (keeping the current numerator).
    private var denominatorSelection: Binding<Int> {
        Binding(get: { viewModel.timeSignature.denominator },
                set: { viewModel.setDenominator($0) })
    }

    var body: some View {
        Card("Time signature") {
            Text(viewModel.timeSignature.displayString)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)   // the wheels below carry the accessible values

            // Two roll-to-select wheels: beats-per-bar (1–32) beside the beat unit (2/4/8/16), split by "/".
            HStack(spacing: 4) {
                wheel(selection: numeratorSelection,
                      values: Array(TimeSignature.numeratorRange),
                      label: "Beats per bar",
                      value: "\(viewModel.timeSignature.numerator)")

                Text("/")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)

                wheel(selection: denominatorSelection,
                      values: TimeSignature.allowedDenominators,
                      label: "Beat unit",
                      value: "\(viewModel.timeSignature.denominator)")
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Quick accent groupings for asymmetric meters (e.g. 7/8 as 2+2+3 or 3+2+2). Each sets the
            // downbeat strong and every subsequent group head to a secondary (medium) accent. These shape
            // the accents, not the meter, so they stay alongside the wheels.
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

    /// One roll-to-select wheel `Picker` over `values`, styled to read as a distinct column inside the card.
    private func wheel(selection: Binding<Int>, values: [Int], label: String, value: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(values, id: \.self) { v in
                Text("\(v)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tag(v)
            }
        }
        .labelsHidden()
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        .accessibilityValue(value)
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
