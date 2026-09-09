import SwiftUI

/// The **silent-practice** section rendered inside the unified Settings screen (under its own "Silent
/// practice" collapsible). Silent practice is a mode set occasionally — not a primary control like tempo
/// or meter — so it lives here rather than on the main screen. It offers, in order of prominence:
///   * a big speaker toggle that silences ALL audio (and restores it),
///   * a Full / Count / Flash preset selector (the "just count" and "just flash" modes), and
///   * an always-visible status line + three independent channel chips, so a muted-but-running metronome
///     is never mistaken for a stopped one.
///
/// Every control routes through `MetronomeViewModel`, which gates the engine with pure gain gates — the
/// tick grid and timing are never touched. Rendered **card-less** (the Settings `CollapsibleSection`
/// supplies the titled surface), matching the other Settings sections. On the main screen, only a tiny
/// `MutedIndicator` appears — under the transport, when audio is muted.
struct MuteControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                // Mute-all speaker toggle — the fast "silence everything" affordance.
                Button { viewModel.toggleMuteAllAudio() } label: {
                    Image(systemName: viewModel.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 58, height: 48)
                }
                .buttonStyle(SelectableStyle(isOn: viewModel.isAudioMuted))
                .accessibilityLabel(viewModel.isAudioMuted ? "Unmute all audio" : "Mute all audio")

                // Preset selector: Full / Count / Flash.
                HStack(spacing: 6) {
                    ForEach(MutePreset.allCases) { preset in
                        Button { viewModel.applyMutePreset(preset) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: preset.symbolName)
                                    .font(.system(size: 15, weight: .bold))
                                Text(preset.displayName)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(SelectableStyle(isOn: viewModel.mutePreset == preset))
                        .accessibilityLabel("\(preset.displayName) mode")
                        .accessibilityHint(preset.statusLabel)
                    }
                }
            }

            // Always-visible status so silent-but-running is unmistakable.
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .bold))
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(statusColor)
            .frame(maxWidth: .infinity)

            // The three independent channels behind the presets — for fine control (and the only way to
            // turn the on-screen visual off for pure-audio practice).
            VStack(alignment: .leading, spacing: 6) {
                Text("CHANNELS")
                    .font(.system(size: 11, weight: .bold)).tracking(1.1)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    channelChip("Click", on: viewModel.channels.click) { viewModel.setClickChannel($0) }
                    channelChip("Voice", on: viewModel.channels.voice) { viewModel.setVoiceChannel($0) }
                    channelChip("Visual", on: viewModel.channels.visual) { viewModel.setVisualChannel($0) }
                }
            }
        }
    }

    private func channelChip(_ title: String, on: Bool,
                             _ toggle: @escaping (Bool) -> Void) -> some View {
        Button { toggle(!on) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(SelectableStyle(isOn: on))
        .accessibilityLabel("\(title) channel")
        .accessibilityValue(on ? "on" : "off")
    }

    private var statusText: String {
        if let preset = viewModel.mutePreset { return preset.statusLabel }
        let c = viewModel.channels
        return [c.click ? "click on" : "click muted",
                c.voice ? "voice on" : "voice muted",
                c.visual ? "visual on" : "visual off"].joined(separator: " · ")
    }

    private var statusSymbol: String {
        if viewModel.isAudioMuted { return "speaker.slash.fill" }
        if viewModel.mutePreset == .countOnly { return "person.wave.2.fill" }
        return "speaker.wave.2.fill"
    }

    private var statusColor: Color {
        viewModel.isFullOutput ? Theme.textSecondary : Theme.accentStrong
    }
}
