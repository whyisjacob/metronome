import Foundation

/// Absolute-time haptic clock: delayed UI ticks skip ahead, never accumulate drift or replay a burst.
/// WatchKit ultimately controls haptic onset; unlike the audio engine these are not sample-accurate.
struct WatchBeatClock {
    struct Beat: Equatable {
        var time: Double
        var number: Int
        var section: Int?
        var bar: Int
        var serial: Int
        var leadIn: Bool = false
    }
    private let events: [Beat]
    private let manual: MetronomeConfiguration?
    private let leadDuration: Double
    let duration: Double?

    init(snapshot: WatchSnapshot) {
        let rate = 48_000.0
        if let song = snapshot.song?.playbackScaled(), let first = song.sections.first {
            manual = nil
            let plan = SongPlan(song: song, sampleRate: rate)
            let pickup = SongPreroll(section: first, pickupTicks: song.pickupTicks,
                                     downbeatFrame: 0, sampleRate: rate, speakSubdivisions: false)
            leadDuration = Double(pickup.span) / rate
            var beats: [Beat] = []
            for click in pickup.clicks {
                if case .number(let number) = click.token {
                    beats.append(Beat(time: Double(click.frame + pickup.span) / rate,
                                      number: number + 1, section: 0, bar: 0,
                                      serial: beats.count, leadIn: true))
                }
            }
            for index in 0..<plan.clickCount {
                if let number = plan.beatInBar(at: index) {
                    beats.append(Beat(time: Double(plan.frame(at: index) + pickup.span) / rate,
                                      number: number + 1, section: plan.sectionIndex(at: index),
                                      bar: plan.barInSection(at: index) + 1, serial: beats.count))
                }
            }
            events = beats
            duration = Double(plan.totalFrames + pickup.span) / rate
        } else {
            manual = snapshot.config
            let count = Pickup(ticks: snapshot.pickupTicks).effectiveTicks(ticksPerBar: snapshot.config.ticksPerBar)
            let plan = RenderPlan(config: snapshot.config, sampleRate: rate, pickup: Pickup(ticks: count))
            leadDuration = Double(plan.frame(forTick: count)) / rate
            var beats: [Beat] = []
            for tick in 0..<count {
                if let number = plan.beatIndex(forTick: tick) {
                    beats.append(Beat(time: Double(plan.frame(forTick: tick)) / rate,
                                      number: number + 1, section: nil, bar: 0,
                                      serial: beats.count, leadIn: true))
                }
            }
            events = beats
            duration = nil
        }
    }

    func beat(at elapsed: Double) -> Beat? {
        guard elapsed >= 0, duration.map({ elapsed < $0 }) ?? true else { return nil }
        if let config = manual, elapsed >= leadDuration {
            let index = Int(floor((elapsed - leadDuration) / config.secondsPerBeat))
            return Beat(time: leadDuration + Double(index) * config.secondsPerBeat,
                        number: index % config.beatsPerBar + 1, section: nil,
                        bar: index / config.beatsPerBar + 1, serial: events.count + index)
        }
        var lower = 0, upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].time <= elapsed { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? events[lower - 1] : nil
    }
}
