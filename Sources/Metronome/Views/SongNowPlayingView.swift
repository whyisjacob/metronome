import SwiftUI

/// The song's display ON the main metronome screen — shown in place of the single-tempo controls while a
/// song is loaded. NOT a separate player: it reads the SAME `MetronomeViewModel` that drives the one
/// engine, so the beat visual above it and this strip reflect the same playback. Provides the song title,
/// transport (pause/resume + restart-section + prev/next), a non-destructive master-tempo control, and a
/// live section-progress list. Styled with the app's `Card`/`Theme` idiom.
struct SongNowPlayingView: View {
    @ObservedObject var viewModel: MetronomeViewModel
    let song: Song

    var body: some View {
        VStack(spacing: 16) {
            titleHeader
            nowPlayingCard
            transportRow
            masterTempoCard
            sectionProgressCard
            exitButton
        }
    }

    // MARK: - Title (P2.4 — prominent, no longer a tiny eyebrow)

    private var titleHeader: some View {
        VStack(spacing: 2) {
            Text(song.name)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(song.sections.count) sections · \(song.totalBars) bars · \(Self.duration(song))")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Now playing

    private var nowPlayingCard: some View {
        Card {
            VStack(spacing: 8) {
                if let section = viewModel.currentSongSection {
                    Text(section.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accentNormal)
                    Text("\(song.resultingBPM(section.tempoBPM)) BPM · \(section.meterAndFeel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bar \(min(viewModel.currentSongBar, section.totalBars)) of \(section.totalBars)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    if let next = viewModel.nextSongSection {
                        Label("Up next: \(next.name) — \(song.resultingBPM(next.tempoBPM)) BPM \(next.timeSignature.displayString)",
                              systemImage: "arrow.turn.down.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    } else {
                        Text("Final section").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    }
                } else {
                    Text(viewModel.songFinished ? "Finished" : "Ready")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.songFinished ? "Tap play to run it again." : "Tap play to start.")
                        .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Transport (P2.3 — pause/resume + restart section + prev/next)

    private var transportRow: some View {
        HStack(spacing: 18) {
            transportIcon("arrow.counterclockwise", "Restart section") { viewModel.restartCurrentSection() }
            transportIcon("backward.fill", "Previous section") { viewModel.skipToPreviousSection() }
            Button { viewModel.toggle() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
                    .foregroundStyle(viewModel.isPlaying ? Theme.stop : Theme.start)
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : (viewModel.songPaused ? "Resume" : "Play"))
            transportIcon("forward.fill", "Next section") { viewModel.skipToNextSection() }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 52, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
        }
        .accessibilityLabel(label)
    }

    // MARK: - Master tempo (P3.8 — non-destructive % scale)

    private var masterTempoCard: some View {
        Card("Master tempo") {
            HStack(spacing: 12) {
                Text("\(Int((viewModel.tempoScale * 100).rounded()))%")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(viewModel.tempoScale == 1.0 ? Theme.textPrimary : Theme.accentNormal)
                Spacer(minLength: 8)
                if viewModel.tempoScale != 1.0 {
                    Button("Reset") { viewModel.resetTempoScale() }
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(PillButtonStyle())
                }
                Button { viewModel.setTempoScale(viewModel.tempoScale - 0.05) } label: {
                    Image(systemName: "minus").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 40)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(viewModel.tempoScale <= Song.tempoScaleRange.lowerBound)
                .accessibilityLabel("Slower")
                Button { viewModel.setTempoScale(viewModel.tempoScale + 0.05) } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 40)
                }
                .buttonStyle(PillButtonStyle())
                .disabled(viewModel.tempoScale >= Song.tempoScaleRange.upperBound)
                .accessibilityLabel("Faster")
            }
            Text("Scales the whole song up/down — every section's BPM moves proportionally (ratios kept). Original section tempos are untouched; the resulting BPMs are shown below.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Section progress (shows each section's RESULTING BPM live)

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
                        Text("\(song.resultingBPM(section.tempoBPM)) · \(section.timeSignature.displayString) · \(section.barsSummary)")
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
