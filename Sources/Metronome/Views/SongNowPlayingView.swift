import SwiftUI

/// The song's display ON the main metronome screen — shown in place of the single-tempo tempo/meter/
/// subdivision controls while a song is loaded. It is NOT a separate player: it reads the SAME
/// `MetronomeViewModel` that drives the one engine, so the beat visual above it and this strip reflect the
/// same playback. Styled with the app's `Card`/`Theme` idiom so it is indistinguishable from the rest.
struct SongNowPlayingView: View {
    @ObservedObject var viewModel: MetronomeViewModel
    let song: Song

    var body: some View {
        VStack(spacing: 16) {
            nowPlayingCard
            TransportButton(isPlaying: viewModel.isPlaying) { viewModel.toggle() }
            sectionProgressCard
            exitButton
        }
    }

    // MARK: - Now playing

    private var nowPlayingCard: some View {
        Card {
            VStack(spacing: 8) {
                Text(song.name.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Theme.textSecondary)

                if let section = viewModel.currentSongSection {
                    Text(section.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accentNormal)
                    Text("\(section.tempoSummary) · \(section.meterAndFeel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bar \(min(viewModel.currentSongBar, section.totalBars)) of \(section.totalBars)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    if let next = viewModel.nextSongSection {
                        Label("Up next: \(next.name) — \(next.tempoSummary) \(next.timeSignature.displayString)",
                              systemImage: "arrow.turn.down.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    } else {
                        Text("Final section")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    }
                } else {
                    Text(viewModel.songFinished ? "Finished" : "Ready")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.songFinished ? "Tap play to run it again."
                                                : "\(song.sections.count) sections · \(song.totalBars) bars · \(Self.duration(song))")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Section progress

    private var sectionProgressCard: some View {
        Card("Sections") {
            VStack(spacing: 6) {
                ForEach(Array(song.sections.enumerated()), id: \.element.id) { entry in
                    let isCurrent = entry.offset == viewModel.currentSectionIndex
                    let section = entry.element
                    HStack(spacing: 10) {
                        Image(systemName: isCurrent ? "play.fill" : "circle.fill")
                            .font(.system(size: isCurrent ? 12 : 7))
                            .foregroundStyle(isCurrent ? Theme.accentNormal : Theme.beatIdle)
                            .frame(width: 16)
                        Text(section.name)
                            .font(.system(size: 14, weight: isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? Theme.textPrimary : Theme.textSecondary)
                        Spacer(minLength: 8)
                        Text("\(section.tempoSummary) · \(section.timeSignature.displayString) · \(section.barsSummary)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var exitButton: some View {
        Button { viewModel.exitSong() } label: {
            Label("Exit song", systemImage: "xmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityHint("Returns to the single-tempo metronome")
    }

    private static func duration(_ song: Song) -> String {
        let total = Int(song.durationSeconds.rounded())
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
    }
}
