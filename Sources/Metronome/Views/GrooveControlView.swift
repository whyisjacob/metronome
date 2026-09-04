import SwiftUI

/// The "Groove" settings section: a continuous **swing** amount and an idiomatic **rhythm cell** picker.
///
/// Both shape the *feel* of the subdivision without ever touching the sample-accurate onset grid's
/// integrity: swing displaces only the off-beat eighth/sixteenth pair members (the main beats never move),
/// and a cell simply silences some sixteenth sub-positions. Defaults (0% swing, cell Off) leave the
/// metronome perfectly straight.
struct GrooveControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private var swingPercent: Int { Int((viewModel.swing * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            swingControl
            Rectangle().fill(Theme.stroke).frame(height: 1)
            cellControl
        }
    }

    // MARK: - Swing

    private var swingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Swing")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(swingPercent == 0 ? "Straight"
                     : (swingPercent >= 100 ? "100% · full triplet" : "\(swingPercent)%"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(swingPercent == 0 ? Theme.textSecondary : Theme.accentNormal)
            }

            Slider(value: Binding(get: { viewModel.swing },
                                  set: { viewModel.setSwing($0) }),
                   in: 0...1)
                .tint(Theme.start)

            Text("Delays the off-beats toward the triplet position — the shuffle feel. Applies to the eighth and sixteenth subdivisions; the main beats stay put.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Idiomatic cells

    private var cellControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pattern")
                .font(.system(size: 15, weight: .semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(RhythmCell.allCases) { cell in
                    Button { viewModel.setCell(cell) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cell.displayName)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text(cell.caption)
                                .font(.system(size: 11))
                                .foregroundStyle(viewModel.cell == cell
                                                 ? Theme.background.opacity(0.7) : Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.cell == cell))
                }
            }

            Text("Idiomatic figures on the sixteenth grid — only the pattern's notes sound, the downbeat accented. Select the Sixteenth subdivision to hear it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
