import Foundation

/// Absolute-time haptic clock. Every grid tick is retained, including subdivisions and pickups.
/// Delayed UI ticks skip ahead rather than accumulating drift or replaying a burst.
/// WatchKit controls physical haptic onset; this is not sample-accurate audio output.
struct WatchBeatClock {
    struct Beat: Equatable {
        var time: Double
        var number: Int
        var section: Int?
        var bar: Int
        var serial: Int
        var leadIn: Bool = false
        var muted: Bool = false
    }
    private static let rate = 48_000.0
    private let events: [Beat]
    private let manual: RenderPlan?
    let duration: Double?

    init(snapshot: WatchSnapshot) {
        let rate = Self.rate
        if let song = snapshot.song?.playbackScaled(), let first = song.sections.first {
            manual = nil
            let plan = SongPlan(song: song, sampleRate: rate)
            let pickup = SongPreroll(section: first, pickupTicks: song.pickupTicks,
                                     downbeatFrame: 0, sampleRate: rate)
            let pickupPlan = RenderPlan(config: first.configuration, sampleRate: rate,
                                        pickup: Pickup(ticks: song.pickupTicks))
            var beats: [Beat] = []
            for (tick, click) in pickup.clicks.enumerated() {
                let number = (pickupPlan.extendedTick(tick) / pickupPlan.ticksPerBeat) % pickupPlan.beatsPerBar + 1
                beats.append(Beat(time: Double(click.frame + pickup.span) / rate,
                                  number: number, section: 0, bar: 0,
                                  serial: beats.count, leadIn: true, muted: click.accent == .muted))
            }
            var localTick = 0
            var previousSection = -1
            for index in 0..<plan.clickCount {
                let sectionIndex = plan.sectionIndex(at: index)
                if sectionIndex != previousSection { localTick = 0; previousSection = sectionIndex }
                let section = song.sections[sectionIndex]
                let number = (localTick / section.ticksPerBeat) % section.beatsPerBar + 1
                beats.append(Beat(time: Double(plan.frame(at: index) + pickup.span) / rate,
                                  number: number, section: sectionIndex,
                                  bar: plan.barInSection(at: index) + 1, serial: beats.count,
                                  muted: plan.accent(at: index) == .muted))
                localTick += 1
            }
            events = beats
            duration = Double(plan.totalFrames + pickup.span) / rate
        } else {
            manual = RenderPlan(config: snapshot.config, sampleRate: rate,
                                pickup: Pickup(ticks: snapshot.pickupTicks))
            events = []
            duration = nil
        }
    }

    func beat(at elapsed: Double) -> Beat? {
        guard elapsed.isFinite, elapsed >= 0, duration.map({ elapsed < $0 }) ?? true else { return nil }
        if let plan = manual {
            // Swing moves a tick within its pair. A whole extra bar bounds that displacement
            // and pickup offset; binary search keeps arbitrarily late polls inexpensive.
            var lower = 0
            var upper = Int(ceil(elapsed / plan.secondsPerTick)) + plan.ticksPerBar + 2
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if Double(plan.frame(forTick: middle)) / Self.rate <= elapsed { lower = middle + 1 }
                else { upper = middle }
            }
            let tick = max(0, lower - 1)
            let pickupTicks = plan.pickup.effectiveTicks(ticksPerBar: plan.ticksPerBar)
            let leadIn = tick < pickupTicks
            return Beat(time: Double(plan.frame(forTick: tick)) / Self.rate,
                        number: (plan.extendedTick(tick) / plan.ticksPerBeat) % plan.beatsPerBar + 1,
                        section: nil, bar: leadIn ? 0 : (tick - pickupTicks) / plan.ticksPerBar + 1,
                        serial: tick, leadIn: leadIn, muted: plan.accentLevel(forTick: tick) == .muted)
        }
        var lower = 0, upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].time <= elapsed { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? events[lower - 1] : nil
    }
}
