import SwiftUI

/// Subdivision selector. In a simple meter: quarter / eighth / triplet / sixteenth / quintuplet /
/// sextuplet / septuplet / 32nd — a wide range of even divisions and tuplets. In a compound meter (6/8,
/// 9/8, 12/8) the beat is a dotted quarter, so the choices become the main beat, its eighths (the
/// 3-per-beat compound pulse), and its sixteenths.
struct SubdivisionControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private var isCompound: Bool { viewModel.timeSignature.isCompound }
    private var options: [Subdivision] { isCompound ? Subdivision.compoundCases : Subdivision.allCases }

    /// A wrapping grid so the eight simple-meter options (and the three compound ones) all fit without
    /// crushing the tap targets on a phone.
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        Card("Subdivision") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(options) { option in
                    Button(action: { viewModel.setSubdivision(option) }) {
                        VStack(spacing: 2) {
                            Text(option.symbol)
                                .font(.system(size: 20, weight: .bold))
                            Text(isCompound ? option.compoundDisplayName : option.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.subdivision == option))
                }
            }
            if isCompound {
                Text("Compound meter — felt in \(viewModel.timeSignature.beatsPerBar). Main beat clicks the dotted-quarter pulse; Eighths adds the 3-per-beat pulse.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
