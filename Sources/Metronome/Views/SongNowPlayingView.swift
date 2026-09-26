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
            transportRow
            nowPlayingCard
            // Silent practice moved to the Settings "Silent practice" section; here we surface only a tiny
            // "Silent" tag under the transport when all audio is muted, so a muted-but-running song doesn't
            // read as broken. Indicator only — the controls live in Settings.
            if viewModel.isAudioMuted {
                MutedIndicator()
            }
            masterTempoCard
            sectionProgressCard
            exitButton
        }
    }

    // MARK: - Title (P2.4 — prominent, no longer a tiny eyebrow)

    private var titleHeader: some View {
        VStack(spacing: 2) {
            Text(song.name)
                .font(.system(size: 26, weight: .semibold, design: .default))
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
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .foregroundStyle(Theme.accentNormal)
                    Text("\(song.resultingBPM(section.tempoBPM)) BPM (\(section.timeSignature.beatUnitName.lowercased())) · \(section.meterAndFeel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.isSongLeadIn ? "Lead-in · \(section.name) starts next" : "Bar \(min(viewModel.currentSongBar, section.totalBars)) of \(section.totalBars)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    if viewModel.isSongLeadIn {
                        Button("Skip lead-in") { viewModel.skipSongLeadIn() }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityHint("Starts this section immediately on its first beat")
                    }
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
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .foregroundStyle(Theme.textPrimary)
                    Text(viewModel.songFinished ? "Tap Replay song to start again." : "Tap Start song to begin.")
                        .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Transport (P2.3 — pause/resume + restart section + prev/next)

    private var transportRow: some View {
        VStack(spacing: 14) {
            TransportButton(isPlaying: viewModel.isPlaying,
                            startTitle: viewModel.songFinished ? "Replay song" : (viewModel.songPaused ? "Resume song" : "Start song"),
                            stopTitle: "Stop song") {
                viewModel.toggle()
            }
            .accessibilityHint(viewModel.isPlaying ? "Stops playback and keeps your place" : "Plays the song")
            HStack(spacing: 24) {
                transportIcon("backward.fill", "Previous") { viewModel.skipToPreviousSection() }
                transportIcon("arrow.counterclockwise", "Restart") { viewModel.restartCurrentSection() }
                transportIcon("forward.fill", "Next") { viewModel.skipToNextSection() }
                    .disabled(viewModel.nextSongSection == nil)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 52, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityLabel("\(label) section")
    }

    // MARK: - Master tempo (P3.8 — non-destructive % scale)

    private var masterTempoCard: some View {
        Card("Master tempo") {
            HStack(spacing: 12) {
                Text("\(Int((viewModel.tempoScale * 100).rounded()))%")
                    .font(.system(size: 24, weight: .semibold, design: .default))
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
            Text("Tap a section to jump to it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            VStack(spacing: 6) {
                ForEach(Array(song.sections.enumerated()), id: \.element.id) { entry in
                    let isCurrent = entry.offset == viewModel.currentSectionIndex
                    let section = entry.element
                    Button { viewModel.selectSongSection(entry.offset) } label: {
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
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(section.name)")
                    .accessibilityHint("Jumps to the start of this section")
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
