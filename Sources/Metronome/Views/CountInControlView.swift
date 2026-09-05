import SwiftUI

/// The pickup / count-in control: choose how long the lead-in is before the first downbeat. A pickup is
/// the *tail* of a bar, so the count-in speaks/shows the last clicks of the bar (e.g. a 2-beat pickup in
/// 4/4 counts "3, 4"; a ½-beat eighth pickup counts the "& of 4") and then the STRONG downbeat "1".
///
/// The count-in is denominated in grid TICKS, so sub-beat pickups are available; the control surfaces them
/// in friendly note-value terms ("½ beat", "1 beat", …) and clamps to `ticksPerBar − 1` for the current
/// grid, re-clamping automatically when the meter or subdivision changes (see `MetronomeViewModel`). Lives
/// in the "Count-in" section of the unified Settings screen, which supplies the titled container.
struct CountInControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.maxPickupTicks < 1 {
                Text("This grid is too short for a count-in. Choose a meter with at least 2 beats per bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CountInStepperRow(label: viewModel.pickupNoteValueLabel(ticks: viewModel.pickupTicks),
                                  ticks: viewModel.pickupTicks,
                                  maxTicks: viewModel.maxPickupTicks,
                                  onChange: { viewModel.setPickupTicks($0) })

                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A live preview of exactly what the count-in will say — built from the same `voiceToken` the engine
    /// plays, so it can never disagree with the audio. Sub-beat pickups show their syllable (e.g. "&").
    private var caption: String {
        let tokens = viewModel.pickupPreviewTokens
        guard !tokens.isEmpty else {
            return "Off — playback starts on the downbeat. Add a count-in for a lead-in before beat 1."
        }
        return "Counts “\(tokens.joined(separator: " "))” then the strong downbeat “1” — once, then the bar "
            + "loops. The lead-in uses a distinct, softer tone so you hear it as a pickup."
    }
}

/// A compact −/value/+ stepper for the count-in length (in ticks), showing a friendly note-value label
/// ("Off", "½ beat", "1 beat", …). Matches the app's pill styling (the gap trainer uses the same shape).
private struct CountInStepperRow: View {
    let label: String
    let ticks: Int
    let maxTicks: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("COUNT-IN")
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(action: { onChange(max(0, ticks - 1)) }) {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(ticks <= 0)
            .accessibilityLabel("Shorter count-in")

            Text(label)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .frame(minWidth: 84)
                .monospacedDigit()
                .multilineTextAlignment(.center)

            Button(action: { onChange(min(maxTicks, ticks + 1)) }) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(ticks >= maxTicks)
            .accessibilityLabel("Longer count-in")
        }
    }
}
