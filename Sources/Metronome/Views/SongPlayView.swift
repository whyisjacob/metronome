import SwiftUI

/// Plays a song: runs it through the engine, auto-advances bar-by-bar and section-by-section, and shows
/// the selected visual indicator plus the current section, bar, and upcoming change.
struct SongPlayView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: VisualSettingsStore
    @StateObject private var model: SongPlayerViewModel

    /// Display-rate ticker that refreshes the on-screen state. Cosmetic only — sounding is
    /// sample-accurate in the audio engine and never depends on this timer.
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    init(song: Song, settings: VisualSettingsStore) {
        _settings = ObservedObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: SongPlayerViewModel(song: song))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                header
                Spacer(minLength: 8)
                BeatVisualView(style: settings.indicatorStyle, state: model.visualState)
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                nowPlaying
                Spacer(minLength: 8)
                upNext
                TransportButton(isPlaying: model.isPlaying) { model.toggle() }
            }
            .padding(20)

            BorderFlashOverlay(flashID: model.flashID,
                               isOnBeat: model.isOnBeat,
                               accentLevel: model.activeAccent,
                               enabled: settings.borderFlashEnabled,
                               accentColor: settings.accentFlashColor,
                               normalColor: settings.normalFlashColor)
        }
        .foregroundStyle(Theme.textPrimary)
        .onReceive(ticker) { _ in model.poll() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack {
            Text(model.song.name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button("Done") { model.stop(); dismiss() }
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var nowPlaying: some View {
        if let section = model.currentSection {
            VStack(spacing: 8) {
                Text(section.name.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(Theme.accentNormal)
                Text(section.tempoSummary)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(section.meterAndFeel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Bar \(min(model.currentBar, section.totalBars)) of \(section.totalBars)")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
        } else {
            VStack(spacing: 10) {
                Text(model.didFinish ? "Finished" : "Ready")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(model.didFinish ? "Tap Start to play again" : "Tap Start to play the song")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var upNext: some View {
        if let next = model.nextSection {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(Theme.textSecondary)
                Text("Up next: \(next.name) — \(next.tempoSummary) \(next.timeSignature.displayString)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        } else if model.isPlaying {
            Text("Final section")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}
