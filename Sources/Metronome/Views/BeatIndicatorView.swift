import SwiftUI

/// The visual beat indicator: a large disc that flashes on every click (brighter/stronger on an
/// accent) plus a row of per-beat dots showing position in the bar. Driven by the view model's
/// polled pulse state, so it tracks the audio.
struct BeatIndicatorView: View {
    let beatCount: Int
    let activeBeat: Int?
    let accents: [Bool]
    let accent: AccentLevel
    let flashID: UInt64
    let isPlaying: Bool

    @State private var popped = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(discColor)
                    .frame(width: 156, height: 156)
                    .scaleEffect(popped ? 1.06 : 0.9)
                    .shadow(color: discColor.opacity(0.65), radius: popped ? 28 : 8)
                Text(centerLabel)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.background)
            }
            .animation(.easeOut(duration: 0.12), value: popped)
            .onChange(of: flashID) { _, _ in
                popped = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { popped = false }
            }

            HStack(spacing: 10) {
                ForEach(Array(0..<max(beatCount, 1)), id: \.self) { i in
                    Circle()
                        .fill(Theme.beatColor(isActive: isPlaying && activeBeat == i,
                                              accented: accents.indices.contains(i) && accents[i]))
                        .frame(width: dotSize(for: i), height: dotSize(for: i))
                        .animation(.easeOut(duration: 0.08), value: activeBeat)
                }
            }
        }
    }

    private var discColor: Color {
        guard isPlaying else { return Theme.surfaceRaised }
        switch accent {
        case .strong: return Theme.accentStrong
        case .normal: return Theme.accentNormal
        case .weak:   return Theme.accentNormal.opacity(0.7)
        }
    }

    private var centerLabel: String {
        guard isPlaying, let beat = activeBeat else { return "—" }
        return "\(beat + 1)"
    }

    /// The accented beats read a touch larger.
    private func dotSize(for index: Int) -> CGFloat {
        (accents.indices.contains(index) && accents[index]) ? 16 : 12
    }
}
