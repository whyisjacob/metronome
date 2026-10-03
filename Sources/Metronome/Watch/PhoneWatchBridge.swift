import Combine
import Foundation

@MainActor
final class PhoneWatchBridge {
    private weak var model: MetronomeViewModel?
    private let link = WatchLink()
    private var ownership = WatchOwnership()
    private var subscriptions = Set<AnyCancellable>()
    private var revision = UserDefaults.standard.integer(forKey: "watchSyncRevision")

    init(model: MetronomeViewModel) {
        self.model = model
        ownership = WatchOwnership(token: UserDefaults.standard.string(forKey: "phoneWatchClaim"))
        model.watchOwnsPlayback = ownership.token != nil
        link.onRequest = { [weak self] request, reply in self?.receive(request, reply: reply) }
        link.onAvailability = { [weak self] available in
            self?.model?.watchAvailable = self?.link.installed ?? false
            self?.model?.watchStatus = available ? "Watch connected" : "Open Maelzel on your watch to connect"
            self?.publish()
        }
        link.onError = { [weak model] message in model?.watchStatus = message }
        Publishers.CombineLatest3(model.$config, model.$activeSong, model.$pickup)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }.store(in: &subscriptions)
        link.activate()
    }

    private func snapshot() -> WatchSnapshot? {
        guard let model else { return nil }
        revision += 1
        UserDefaults.standard.set(revision, forKey: "watchSyncRevision")
        return WatchSnapshot(revision: revision, config: model.config, song: model.activeSong,
                             pickupTicks: model.pickupTicks)
    }

    private func publish() { if let snapshot = snapshot() { link.publish(snapshot) } }

    private func receive(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let model, let action = request["action"] as? String else { reply(["ok": false]); return }
        switch action {
        case "claim", "fetch":
            guard let snapshot = snapshot(), let data = try? JSONEncoder().encode(snapshot), data.count < 60_000 else {
                reply(["ok": false, "error": "This song is too large to sync."]); return
            }
            if action == "claim" {
                model.stop()
                let token = ownership.claim()
                UserDefaults.standard.set(token, forKey: "phoneWatchClaim")
                model.watchOwnsPlayback = true
                model.watchStatus = "Playing on Apple Watch"
                reply(["ok": true, "settings": data, "token": token])
            } else { reply(["ok": true, "settings": data]) }
        case "release":
            if let token = request["token"] as? String, ownership.release(token) {
                UserDefaults.standard.removeObject(forKey: "phoneWatchClaim")
                model.watchOwnsPlayback = false
                model.watchStatus = "Watch connected"
            }
            reply(["ok": true])
        case "tempo":
            guard request["songID"] as? String == (model.activeSong?.id.uuidString ?? "manual") else {
                reply(["ok": false]); return
            }
            guard let value = request["value"] as? Double, value.isFinite else { reply(["ok": false]); return }
            if model.activeSong != nil { model.setTempoScale(value / 100) }
            else { model.setBPM(value) }
            replySettings(reply)
        case "meter":
            guard model.activeSong == nil, let numerator = request["numerator"] as? Int,
                  let denominator = request["denominator"] as? Int else { reply(["ok": false]); return }
            model.setNumerator(numerator)
            model.setDenominator(denominator)
            replySettings(reply)
        default: reply(["ok": false])
        }
    }

    private func replySettings(_ reply: ([String: Any]) -> Void) {
        guard let snapshot = snapshot(), let data = try? JSONEncoder().encode(snapshot) else {
            reply(["ok": false]); return
        }
        link.publish(snapshot)
        reply(["ok": true, "settings": data])
    }

    func stopWatch(then completion: (() -> Void)? = nil) {
        guard let token = ownership.token else {
            model?.watchOwnsPlayback = false
            completion?()
            return
        }
        model?.watchStatus = "Stopping watch…"
        link.request(["action": "stop", "token": token]) { [weak self] result in
            guard let self else { return }
            if case .success(let reply) = result, reply["ok"] as? Bool == true {
                guard self.ownership.release(token) else { return }
                UserDefaults.standard.removeObject(forKey: "phoneWatchClaim")
                self.model?.watchOwnsPlayback = false
                self.model?.watchStatus = "Watch connected"
                completion?()
            } else { self.model?.watchStatus = "Stop playback on your watch, then try again." }
        }
    }
}
