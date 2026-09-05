import Foundation

/// Persists the mute / silent-practice choice — the three `OutputChannels` (click / voice / visual) — so
/// it survives relaunch. Modelled on the app's other small stores (`SoundSettingsStore` /
/// `VisualSettingsStore`): an injectable `UserDefaults` (so tests use an isolated suite), plain
/// synchronous reads/writes, and no timing state — it only records WHAT is audible / shown, never *when*.
///
/// The default (a fresh install, or any store not backing a real app) is everything on, so the engine and
/// the accuracy tests are unaffected.
final class MuteSettingsStore: ObservableObject {

    @Published private(set) var channels: OutputChannels

    private let defaults: UserDefaults

    private enum Keys {
        static let click = "mute.click"
        static let voice = "mute.voice"
        static let visual = "mute.visual"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Everything on out of the box: an *absent* key must read as `true` (not the `false` that
        // `bool(forKey:)` would give), so a fresh install is full output.
        let click = defaults.object(forKey: Keys.click) as? Bool ?? true
        let voice = defaults.object(forKey: Keys.voice) as? Bool ?? true
        let visual = defaults.object(forKey: Keys.visual) as? Bool ?? true
        self.channels = OutputChannels(click: click, voice: voice, visual: visual)
    }

    /// Persists the whole channel set. Cheap and synchronous, like the sibling stores.
    func setChannels(_ channels: OutputChannels) {
        self.channels = channels
        defaults.set(channels.click, forKey: Keys.click)
        defaults.set(channels.voice, forKey: Keys.voice)
        defaults.set(channels.visual, forKey: Keys.visual)
    }
}
