import SwiftUI

/// The pickup / count-in control: choose how many lead-in beats sound before the first downbeat. A pickup
/// is the *tail* of a bar, so the count-in speaks/shows the last beats of the bar (e.g. a 2-beat pickup in
/// 4/4 counts "3, 4") and then the STRONG downbeat "1". The stepper clamps to `beatsPerBar − 1` for the
/// current meter and re-clamps automatically when the meter changes (see `MetronomeViewModel`). Lives in
/// the "Count-in" section of the unified Settings screen, which supplies the titled container.
struct CountInControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.maxPickupBeats < 1 {
                Text("This meter has too few beats for a count-in. Choose a meter with at least 2 beats per bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                CountInStepperRow(beats: viewModel.pickupBeats,
                                  maxBeats: viewModel.maxPickupBeats,
                                  onChange: { viewModel.setPickupBeats($0) })

                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if viewModel.pickupBeats > 0 {
                    Toggle(isOn: Binding(get: { viewModel.pickupRepeats },
                                         set: { viewModel.setPickupRepeats($0) })) {
                        Text("Repeat before every bar")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(Theme.start)
                }
            }
        }
    }

    /// Spells out exactly what the count-in will say, computed from first principles: a `k`-beat pickup in
    /// an `N`-beat bar counts beats `N−k+1 … N`, then the downbeat "1".
    private var caption: String {
        let k = viewModel.pickupBeats
        guard k > 0 else {
            return "Off — playback starts on the downbeat. Turn on a count-in for a lead-in before beat 1."
        }
        let n = viewModel.beatsPerBar
        let counts = Array((n - k + 1)...n).map(String.init).joined(separator: ", ")
        let cadence = viewModel.pickupRepeats ? "before every bar" : "once, then the bar loops"
        return "Counts \(counts) as a lead-in, then the strong downbeat “1” — \(cadence). "
            + "The lead-in uses a distinct, softer tone so you hear it as a pickup."
    }
}

/// A compact −/value/+ stepper for the count-in length. Shows "Off" at 0, then the beat count. Matches the
/// app's pill styling (the gap trainer uses the same shape).
private struct CountInStepperRow: View {
    let beats: Int
    let maxBeats: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("PICKUP BEATS")
                .font(.system(size: 12, weight: .bold)).tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(action: { onChange(max(0, beats - 1)) }) {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(beats <= 0)
            .accessibilityLabel("Fewer pickup beats")

            Text(beats == 0 ? "Off" : "\(beats)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(minWidth: 56)
                .monospacedDigit()

            Button(action: { onChange(min(maxBeats, beats + 1)) }) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(beats >= maxBeats)
            .accessibilityLabel("More pickup beats")
        }
    }
}
