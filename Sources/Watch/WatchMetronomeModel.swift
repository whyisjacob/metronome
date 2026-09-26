import SwiftUI
import WatchKit

@MainActor
final class WatchMetronomeModel: ObservableObject {
    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var count = 0
    @Published private(set) var sectionIndex = 0
    @Published private(set) var bar = 0
    @Published private(set) var leadIn = false
    @Published var status = "Open Maelzel on iPhone to sync"
    @Published var output: WatchOutput = .vibration
    private let link = WatchLink()
    private let engine = MetronomeEngine()
    private var token: String?
    private var requestID = UUID()
    private var timer: Timer?
    private var clock: WatchBeatClock?
    private var startTime = 0.0
    private var lastSerial = -1
    private var lastPulse: UInt64 = 0
    private var deferredSnapshot: WatchSnapshot?
    private var foreground = true

    init() {
        output = WatchOutput(rawValue: UserDefaults.standard.string(forKey: "watchOutput") ?? "") ?? .vibration
        if let data = UserDefaults.standard.data(forKey: "watchSnapshot") {
            snapshot = try? WatchSnapshot.decode(data)
        }
        link.onSnapshot = { [weak self] value in self?.receive(value) }
        link.onAvailability = { [weak self] reachable in
            guard let self else { return }
            if reachable {
                if let old = UserDefaults.standard.string(forKey: "watchClaim"), !self.isPlaying {
                    self.link.release(old)
                    UserDefaults.standard.removeObject(forKey: "watchClaim")
                }
                if !self.isPlaying { self.refresh() }
            } else if !self.isPlaying { self.status = "Open Maelzel on iPhone to connect" }
        }
        link.onError = { [weak self] in self?.status = $0 }
        link.onRequest = { [weak self] request, reply in
            guard let self, request["action"] as? String == "stop" else { reply(["ok": false]); return }
            if request["token"] as? String == self.token { self.stop() }
            reply(["ok": true])
        }
        engine.onPlaybackStateChanged = { [weak self] playing in
            if !playing, self?.isPlaying == true, self?.output == .voice { self?.stop() }
        }
        link.activate()
    }

    var currentConfig: MetronomeConfiguration {
        if let song = snapshot?.song?.playbackScaled(), song.sections.indices.contains(sectionIndex) {
            return song.sections[sectionIndex].configuration
        }
        return snapshot?.config ?? MetronomeConfiguration()
    }
    var tempoValue: Double { snapshot?.song.map { $0.tempoScale * 100 } ?? snapshot?.config.bpm ?? 92 }
    var tempoRange: ClosedRange<Double> { snapshot?.song == nil ? 30...300 : 50...200 }
    var tempoUnit: String { snapshot?.song == nil ? "BPM" : "% song tempo" }
    var title: String { snapshot?.song?.name ?? "Maelzel" }

    func refresh() {
        link.request(["action": "fetch"]) { [weak self] result in
            self?.readReply(result)
        }
    }

    private func receive(_ value: WatchSnapshot) {
        guard value.revision > (snapshot?.revision ?? -1) else { return }
        if isPlaying {
            deferredSnapshot = value
            status = "Phone changes ready · Stop to apply"
            return
        }
        snapshot = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "watchSnapshot") }
        status = "Synced with iPhone"
    }

    func toggle() { isPlaying || isBusy ? stop() : start() }

    private func start() {
        guard !isBusy, foreground else { return }
        isBusy = true
        status = "Connecting…"
        let id = UUID()
        requestID = id
        link.request(["action": "claim"]) { [weak self] result in
            guard let self else { return }
            // Cancelled starts can still receive replies. Release the phone claim without sounding.
            guard self.requestID == id, self.foreground else {
                if case .success(let reply) = result, let token = reply["token"] as? String { self.link.release(token) }
                self.isBusy = false
                return
            }
            self.isBusy = false
            guard case .success(let reply) = result, reply["ok"] as? Bool == true,
                  let data = reply["settings"] as? Data, let value = try? WatchSnapshot.decode(data),
                  let token = reply["token"] as? String else {
                self.status = "Open Maelzel on iPhone, then tap Start"
                return
            }
            self.receive(value)
            self.token = token
            UserDefaults.standard.set(token, forKey: "watchClaim")
            self.beginPlayback()
        }
    }

    private func beginPlayback() {
        guard let snapshot else { return }
        count = 0; bar = 0; sectionIndex = 0; lastSerial = -1
        leadIn = snapshot.song.map { $0.pickupTicks > 0 } ?? (snapshot.pickupTicks > 0)
        UserDefaults.standard.set(output.rawValue, forKey: "watchOutput")
        do {
            if output == .voice {
                engine.setSpeakSubdivisions(false)
                engine.setClickMuted(true)
                engine.setVoiceMuted(false)
                lastPulse = engine.currentPulse.sequence
                if var song = snapshot.song?.playbackScaled() {
                    song.voiceEnabled = true
                    for i in song.sections.indices {
                        song.sections[i].voiceEnabled = true
                        song.sections[i].speakSubdivisions = false
                    }
                    try engine.startSong(song)
                } else {
                    var config = snapshot.config
                    config.sound = .voice
                    engine.update(config)
                    engine.setPickup(Pickup(ticks: snapshot.pickupTicks))
                    try engine.start()
                }
            }
            clock = WatchBeatClock(snapshot: snapshot)
            startTime = ProcessInfo.processInfo.systemUptime
            isPlaying = true
            status = output == .vibration ? "Vibration · keep Maelzel visible" : "Spoken count on watch"
            timer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        } catch {
            stop()
            status = "Audio couldn’t start. Check the watch audio output."
        }
    }

    private func tick() {
        guard isPlaying else { return }
        if output == .voice {
            let pulse = engine.currentPulse
            guard snapshot?.song == nil || engine.isCurrentSongPulse(pulse) else { return }
            guard pulse.sequence != lastPulse else { return }
            lastPulse = pulse.sequence
            if pulse.songFinished { stop(); status = "Finished · Start to replay"; return }
            if let beat = pulse.beatIndex { count = beat + 1 }
            sectionIndex = pulse.sectionIndex ?? 0
            bar = (pulse.barInSection ?? 0) + 1
            leadIn = false
        } else {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            if let end = clock?.duration, elapsed >= end { stop(); status = "Finished · Start to replay"; return }
            guard let beat = clock?.beat(at: elapsed), beat.serial != lastSerial else { return }
            lastSerial = beat.serial
            count = beat.number; bar = beat.bar; sectionIndex = beat.section ?? 0; leadIn = beat.leadIn
            // Suppress a late haptic rather than firing a burst after a delayed main-thread tick.
            if elapsed - beat.time < 0.10, foreground { WKInterfaceDevice.current().play(.click) }
        }
    }

    func stop() {
        requestID = UUID()
        isBusy = false
        isPlaying = false
        timer?.invalidate(); timer = nil
        engine.stop()
        if let token { link.release(token) }
        token = nil
        UserDefaults.standard.removeObject(forKey: "watchClaim")
        status = "Stopped"
        if let pending = deferredSnapshot { deferredSnapshot = nil; receive(pending) }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active, output == .vibration, isPlaying || isBusy {
            stop()
            status = "Vibration paused · keep Maelzel visible"
        } else if active { tick() }
    }

    func changeTempo(_ value: Double) {
        guard !isBusy, let snapshot else { return }
        // Edits stop cleanly, sync to the phone, then await an explicit Start. Never silently restart.
        if isPlaying { stop() }
        isBusy = true
        let clamped = min(max(value.rounded(), tempoRange.lowerBound), tempoRange.upperBound)
        link.request(["action": "tempo", "value": clamped,
                      "songID": snapshot.song?.id.uuidString ?? "manual"]) { [weak self] result in
            self?.isBusy = false
            self?.readReply(result)
        }
    }

    func changeMeter(numerator: Int, denominator: Int) {
        if isPlaying { stop() }
        guard !isBusy else { return }
        isBusy = true
        link.request(["action": "meter", "numerator": numerator, "denominator": denominator]) { [weak self] result in
            self?.isBusy = false
            self?.readReply(result)
        }
    }

    private func readReply(_ result: Result<[String: Any], Error>) {
        guard case .success(let reply) = result, reply["ok"] as? Bool == true,
              let data = reply["settings"] as? Data, let value = try? WatchSnapshot.decode(data) else {
            status = "Open Maelzel on iPhone to sync"
            return
        }
        receive(value)
    }
}
