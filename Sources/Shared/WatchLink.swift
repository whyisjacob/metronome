import Foundation
import WatchConnectivity

/// One session per process. WCSession delegate callbacks are delivered to the main actor before UI work.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    var onSnapshot: ((WatchSnapshot) -> Void)?
    var onRequest: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private var pending: WatchSnapshot?
    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    var reachable: Bool { session?.activationState == .activated && session?.isReachable == true }
    var installed: Bool {
        #if os(iOS)
        return session?.isPaired == true && session?.isWatchAppInstalled == true
        #else
        return true
        #endif
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ snapshot: WatchSnapshot) {
        pending = snapshot
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard data.count < 60_000 else {
                onError?("This song is too large to sync to the watch.")
                return
            }
            try session.updateApplicationContext(["settings": data])
            if session.isReachable {
                session.sendMessage(["settings": data], replyHandler: nil, errorHandler: nil)
            }
        } catch { onError?("Settings haven’t synced yet. Open Maelzel on both devices.") }
    }

    func request(_ message: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let session, reachable else {
            completion(.failure(LinkError.unreachable))
            return
        }
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in completion(.success(reply)) }
        }, errorHandler: { error in
            Task { @MainActor in completion(.failure(error)) }
        })
    }

    // Safe to queue: release can only stop ownership of this exact, already-ended session.
    func release(_ token: String) {
        guard let session, session.activationState == .activated else { return }
        let message: [String: Any] = ["action": "release", "token": token]
        if reachable { request(message) { _ in } }
        session.transferUserInfo(message)
    }

    private func receive(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let data = message["settings"] as? Data {
            do { onSnapshot?(try WatchSnapshot.decode(data)); reply(["ok": true]) }
            catch { onError?("Update Maelzel on both devices to sync."); reply(["ok": false]) }
        } else if let onRequest { onRequest(message, reply) }
        else { reply(["ok": false]) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error { self.onError?(error.localizedDescription) }
            if let pending = self.pending { self.publish(pending) }
            if let data = session.receivedApplicationContext["settings"] as? Data {
                self.receive(["settings": data]) { _ in }
            }
            self.onAvailability?(self.reachable)
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.onAvailability?(self.reachable) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.receive(context) { _ in } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.receive(message) { _ in } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in self.receive(message, reply: replyHandler) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.receive(userInfo) { _ in } }
    }
    #if os(iOS)
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.onAvailability?(self.reachable) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
    enum LinkError: Error { case unreachable }
}
