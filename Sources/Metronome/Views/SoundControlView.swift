import SwiftUI

/// Sound picker: the code-synthesized click timbres plus the spoken Voice mode. Selecting a sound takes
/// effect immediately, even mid-playback, and is persisted. Card-less content — it lives inside the
/// "Sound" section of the unified Settings screen, which supplies the titled container.
struct SoundControlView: View {
    @ObservedObject var viewModel: MetronomeViewModel

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(MetronomeSound.allCases) { sound in
                    Button(action: { viewModel.setSound(sound) }) {
                        HStack(spacing: 6) {
                            Image(systemName: sound.symbolName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(sound.displayName)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(SelectableStyle(isOn: viewModel.sound == sound))
                }
            }

            if viewModel.sound.isVoice {
                Text("Voice speaks the count. The first beats may click while the voice prepares. Fine-tune it in the Voice section.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
