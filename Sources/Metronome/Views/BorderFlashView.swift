import SwiftUI

/// A screen-edge flash that pulses once per beat, independent of the chosen indicator. The accent-beat
/// and normal-beat colours are user-selectable (see `VisualSettingsStore`). Purely cosmetic and driven by
/// the same engine pulse as the indicators; it never intercepts touches, and stays dark (opacity 0) while
/// disabled or between beats.
struct BorderFlashOverlay: View {
    /// Bumps once per click; the flash keys off this.
    let flashID: UInt64
    /// Only beat clicks flash the border (not the subdivisions between beats).
    let isOnBeat: Bool
    let accentLevel: AccentLevel
    let enabled: Bool
    let accentColor: FlashColor
    let normalColor: FlashColor

    @State private var flashOn = false
    @State private var currentColor: Color = .clear

    var body: some View {
        Rectangle()
            .strokeBorder(currentColor, lineWidth: 16)
            .ignoresSafeArea()
            .opacity(flashOn ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: flashOn)
            .onChange(of: flashID) { _, _ in
                guard enabled, isOnBeat else { return }
                currentColor = VisualSettingsStore
                    .flashColor(for: accentLevel, accent: accentColor, normal: normalColor)
                    .color
                flashOn = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { flashOn = false }
            }
    }
}
