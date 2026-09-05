import SwiftUI

/// The "Groove" settings section: a continuous **swing** amount and an idiomatic **rhythm cell** picker.
///
/// Both shape the *feel* of the subdivision without ever touching the sample-accurate onset grid's
/// integrity: swing displaces only the off-beat eighth/sixteenth pair members (the main beats never move),
/// and a cell simply silences some sixteenth sub-positions. Defaults (0% swing, cell Off) leave the
/// metronome perfectly straight.
///
/// Swing and cells only shape specific grids (swing → the eighth/sixteenth grid, cells → the sixteenth
/// grid), so the controls are **self-activating**: turning on swing or picking a cell advances the
/// subdivision to the grid that feature needs (see `MetronomeViewModel.setSwing`/`setCell`, which also drives
/// the main-screen subdivision picker). This section surfaces that current grid and tells the truth about
/// whether swing / the cell is actually audible — it never presents a groove as on while playback is straight.
struct GrooveControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private var swingPercent: Int { Int((viewModel.swing * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            gridContext
            swingControl
            Rectangle().fill(Theme.stroke).frame(height: 1)
            cellControl
        }
    }

    // MARK: - Grid context

    /// The subdivision that swing and cells are shaping right now, so the two controls read as coupled to the
    /// grid they act on (and to the main-screen subdivision) rather than as free-floating knobs. Turning on a
    /// groove control moves this automatically.
    private var gridContext: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Current grid: \(viewModel.subdivision.displayName) notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }

    // MARK: - Swing

    private var swingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Swing")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(swingReadout)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(swingReadoutColor)
            }

            Slider(value: Binding(get: { viewModel.swing },
                                  set: { viewModel.setSwing($0) }),
                   in: 0...1)
                .tint(Theme.start)

            Text("Gives the off-beats a shuffle feel, leaning them toward the triplet position — the main beats never move. Swing lives on the eighth/sixteenth grid, so turning it up sets an eighth-note feel automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The swing amount, told truthfully. `0` reads "Straight"; a live value shows its percentage — but if
    /// swing is set on a grid that can't voice it (a compound meter, or a recalled straight config), it says
    /// so instead of implying an audible swing that isn't there.
    private var swingReadout: String {
        guard swingPercent > 0 else { return "Straight" }
        let pct = swingPercent >= 100 ? "100% · full triplet" : "\(swingPercent)%"
        return viewModel.swingIsAudible ? pct : "\(pct) · inactive here"
    }

    private var swingReadoutColor: Color {
        if swingPercent == 0 { return Theme.textSecondary }
        return viewModel.swingIsAudible ? Theme.accentNormal : Theme.textSecondary
    }

    // MARK: - Idiomatic cells

    private var cellControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Pattern")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                if viewModel.cell != .straight {
                    Text(viewModel.cellIsActive ? "On the sixteenth grid" : "Inactive here")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.cellIsActive ? Theme.accentNormal : Theme.textSecondary)
                }
            }

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

            Text("Idiomatic figures on the sixteenth grid — only the pattern's notes sound, the downbeat accented. Picking one switches to the sixteenth grid automatically; “Off” restores the plain pulse.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
