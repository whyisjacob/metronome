import AVFoundation

/// Owns the `AVAudioSession` lifecycle for playback and relays interruption / route-change events
/// back to the engine.
///
/// Configured `.playback` with `.mixWithOthers`; combined with the app's `audio` `UIBackgroundMode`
/// (see project.yml) the click keeps sounding when the screen locks or the app is backgrounded, while
/// still mixing with other apps' audio rather than ducking or stopping them.
///
/// Callbacks may arrive on a non-main thread; the engine is responsible for hopping to the right
/// thread for any UIKit/UI work.
final class AudioSessionController {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onRouteChange: ((_ reason: AVAudioSession.RouteChangeReason) -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observing = false

    /// Sample rate the hardware is actually running at. Valid once the session is active.
    var sampleRate: Double { session.sampleRate }

    /// Idempotent: sets the category and (re)activates the session, and begins observing once.
    func activate() throws {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        startObserving()
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: session)
        nc.addObserver(self, selector: #selector(handleMediaReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            var shouldResume = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                    .contains(.shouldResume)
            }
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        onRouteChange?(reason)
    }

    @objc private func handleMediaReset(_ note: Notification) {
        onMediaServicesReset?()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
