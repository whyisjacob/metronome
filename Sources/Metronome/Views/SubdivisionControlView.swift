import SwiftUI

/// Subdivision selector: quarter / eighth / triplet / sixteenth.
struct SubdivisionControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        Card("Subdivision") {
            HStack(spacing: 8) {
                ForEach(Subdivision.allCases) { option in
                    Button(action: { viewModel.setSubdivision(option) }) {
                        VStack(spacing: 2) {
                            Text(option.symbol)
                                .font(.system(size: 20, weight: .bold))
                            Text(option.displayName)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.subdivision == option))
                }
            }
        }
    }
}
