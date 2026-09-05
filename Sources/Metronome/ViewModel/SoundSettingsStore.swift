import Foundation

/// Persists the audio *preferences* that aren't part of the live, tempo-map-bound
/// `MetronomeConfiguration` but should survive relaunch: the chosen sound (a click timbre or the spoken
/// Voice) and, for Voice, whether the in-between subdivisions are spoken aloud.
///
/// Modelled on `VisualSettingsStore`: an injectable `UserDefaults` (so tests use an isolated suite),
/// plain synchronous reads/writes, and no timing state — it only decides *what* sounds, never *when*.
/// The default (a fresh install, or any store not backing a real app) is the classic click with
/// subdivisions spoken, so the engine and the accuracy tests are unaffected.
final class SoundSettingsStore: ObservableObject {

    @Published private(set) var sound: MetronomeSound
    /// In Voice mode, speak the in-between subdivision syllables ("1 e and a"). On by default.
    @Published private(set) var speakSubdivisions: Bool
    /// Voice-mode spoken volume (0…1), independent of the click volume. Full (1.0) by default.
    @Published private(set) var voiceVolume: Double

    private let defaults: UserDefaults

    private enum Keys {
        static let sound = "sound.selected"
        static let speakSubdivisions = "sound.speakSubdivisions"
        static let voiceVolume = "sound.voiceVolume"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sound = defaults.string(forKey: Keys.sound)
            .flatMap(MetronomeSound.init(rawValue:)) ?? .classic
        // Speaking the subdivisions is the default: an *absent* key must read as `true` (not the `false`
        // that `bool(forKey:)` would give), so "1 e and a" is on out of the box.
        self.speakSubdivisions = defaults.object(forKey: Keys.speakSubdivisions) as? Bool ?? true
        // Full voice volume by default: an absent key must read as 1.0 (not the 0.0 `double(forKey:)`
        // would give), so the voice isn't silent out of the box.
        self.voiceVolume = (defaults.object(forKey: Keys.voiceVolume) as? Double) ?? 1.0
    }

    func setSound(_ sound: MetronomeSound) {
        self.sound = sound
        defaults.set(sound.rawValue, forKey: Keys.sound)
    }

    func setSpeakSubdivisions(_ on: Bool) {
        speakSubdivisions = on
        defaults.set(on, forKey: Keys.speakSubdivisions)
    }

    /// Sets the voice volume (clamped to 0…1) and persists it.
    func setVoiceVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        voiceVolume = clamped
        defaults.set(clamped, forKey: Keys.voiceVolume)
    }
}
