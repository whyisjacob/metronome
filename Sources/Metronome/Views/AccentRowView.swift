import SwiftUI

/// One toggle per beat in the bar; tap to accent/unaccent that beat. The downbeat is accented by
/// default and at least one accent is always kept (enforced by the configuration).
struct AccentRowView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        Card("Accents") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(viewModel.accents.indices), id: \.self) { index in
                    Button(action: { viewModel.toggleAccent(index) }) {
                        Text("\(index + 1)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(AccentCellStyle(isOn: viewModel.accents[index]))
                }
            }
        }
    }
}

/// A beat cell that glows in the accent colour when on.
private struct AccentCellStyle: ButtonStyle {
    var isOn: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Theme.background : Theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isOn ? Theme.accentStrong : Theme.surfaceRaised)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
