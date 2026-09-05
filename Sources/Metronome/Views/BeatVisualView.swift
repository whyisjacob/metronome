import SwiftUI

/// An immutable snapshot the beat-indicator views render from. A view model rebuilds it each display
/// tick from the engine's `BeatPulse` — the single source of truth for *when* a click sounds — so every
/// indicator style stays locked to the audio. It carries no audio or timing logic of its own.
struct BeatVisualState: Equatable {
    /// Beats (pulses) in the current bar.
    var beatsPerMeasure: Int
    /// Subdivision clicks per beat (1 quarter, 2 eighth, 3 triplet, 4 sixteenth, 8 = 32nd).
    var ticksPerBeat: Int
    /// Per-beat accent state (`count == beatsPerMeasure`).
    var accents: [BeatAccent]
    /// The current beat (0-based), held *sticky* across the subdivision clicks between beats; `nil` idle.
    var currentBeat: Int?
    /// 0 on the beat itself, then 1…ticksPerBeat-1 as the subdivisions between this beat and the next
    /// sound — this is what lets the ring / dots / counter reflect the "e / and / a" pulses.
    var subdivisionPhase: Int
    /// Emphasis of the most recent click.
    var accentLevel: AccentLevel
    /// Bumps once per click; indicators key their transient pulse animation off this.
    var flashID: UInt64
    var isPlaying: Bool
    /// Whether the most recent click landed on a beat (vs a subdivision between beats).
    var isOnBeat: Bool

    /// An idle placeholder (nothing sounding).
    static func idle(beatsPerMeasure: Int = 4, ticksPerBeat: Int = 1,
                     accents: [BeatAccent] = [.strong, .normal, .normal, .normal]) -> BeatVisualState {
        BeatVisualState(beatsPerMeasure: beatsPerMeasure, ticksPerBeat: ticksPerBeat, accents: accents,
                        currentBeat: nil, subdivisionPhase: 0, accentLevel: .normal, flashID: 0,
                        isPlaying: false, isOnBeat: false)
    }

    /// Advances the subdivision phase given whether the newest click was a beat. Pure → unit-tested.
    /// A beat resets the phase to 0; a subdivision advances it, capped at `ticksPerBeat - 1`. Because the
    /// engine emits clicks strictly in order, counting subdivisions since the last beat is exact and does
    /// not depend on any global tick index (so it works identically in single-tempo and song modes).
    static func nextSubdivisionPhase(previous: Int, wasBeat: Bool, ticksPerBeat: Int) -> Int {
        guard !wasBeat else { return 0 }
        return min(previous + 1, max(ticksPerBeat - 1, 0))
    }

    /// The accent state of beat `i` (bounds-safe; `.normal` when out of range).
    func accent(_ i: Int) -> BeatAccent { accents.indices.contains(i) ? accents[i] : .normal }

    /// Whether beat `i` carries a primary or secondary accent (drives the emphasized dot size / colour).
    func isAccented(_ i: Int) -> Bool { accent(i) == .strong || accent(i) == .medium }

    /// Whether beat `i` is muted (shown dimmed/hollow — it advances but never sounds).
    func isMuted(_ i: Int) -> Bool { accent(i) == .muted }
}

/// Renders whichever indicator the user selected. A thin switch so callers pass a style + state and stay
/// agnostic to the individual indicator views.
struct BeatVisualView: View {
    let style: BeatIndicatorStyle
    let state: BeatVisualState

    var body: some View {
        switch style {
        case .ball:    BallIndicator(state: state)
        case .dots:    DotsIndicator(state: state)
        case .counter: CounterIndicator(state: state)
        case .ring:    RingIndicator(state: state)
        }
    }
}

// MARK: - Shared pieces

/// A row (or wrapping grid for large meters) of one dot per beat; the active beat lights and accented
/// beats read larger. Shared by the Ball and Dots indicators.
private struct BeatDotsRow: View {
    let state: BeatVisualState
    /// The beat to light (already resolved by the caller — sticky for Dots, on-beat-only for Ball).
    let activeBeat: Int?

    var body: some View {
        let indices = Array(0..<max(state.beatsPerMeasure, 1))
        Group {
            if state.beatsPerMeasure <= 12 {
                HStack(spacing: 10) { ForEach(indices, id: \.self) { dot($0) } }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 18), spacing: 8)], spacing: 8) {
                    ForEach(indices, id: \.self) { dot($0) }
                }
            }
        }
    }

    private func dot(_ i: Int) -> some View {
        Circle()
            .fill(Theme.beatColor(for: state.accent(i), isActive: activeBeat == i))
            .frame(width: size(i), height: size(i))
            .opacity(state.isMuted(i) ? 0.5 : 1)
            .animation(.easeOut(duration: 0.08), value: activeBeat)
    }

    private func size(_ i: Int) -> CGFloat {
        switch state.accent(i) {
        case .strong:          return 16
        case .medium:          return 14
        case .normal, .muted:  return 12
        }
    }
}

/// A short row of pips for the subdivisions within one beat; pips up to the current subdivision phase are
/// lit. Callers hide it for a plain quarter (ticksPerBeat == 1, no subdivisions to show).
private struct SubdivisionPips: View {
    let state: BeatVisualState

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(0..<max(state.ticksPerBeat, 1)), id: \.self) { k in
                Circle()
                    .fill(pipColor(k))
                    .frame(width: k == 0 ? 9 : 7, height: k == 0 ? 9 : 7)
                    .animation(.easeOut(duration: 0.06), value: state.subdivisionPhase)
            }
        }
    }

    private func pipColor(_ k: Int) -> Color {
        guard state.isPlaying else { return Theme.beatIdle }
        return k <= state.subdivisionPhase ? Theme.accentNormal.opacity(k == 0 ? 1.0 : 0.7) : Theme.beatIdle
    }
}

// MARK: - Ball (kept visually identical to v1)

/// The original indicator: a large disc that pops on every click (brighter on an accent) above a row of
/// per-beat dots that light on the beat.
private struct BallIndicator: View {
    let state: BeatVisualState
    @State private var popped = false

    /// The Ball keeps its v1 behaviour: the dots/number blink on beats only (dark between beats).
    private var activeBeat: Int? { state.isOnBeat ? state.currentBeat : nil }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(discColor)
                    .frame(width: 156, height: 156)
                    .scaleEffect(popped ? 1.06 : 0.9)
                    .shadow(color: discColor.opacity(0.65), radius: popped ? 28 : 8)
                Text(centerLabel)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.background)
            }
            .animation(.easeOut(duration: 0.12), value: popped)
            .onChange(of: state.flashID) { _, _ in
                popped = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { popped = false }
            }

            BeatDotsRow(state: state, activeBeat: activeBeat)
        }
    }

    private var discColor: Color {
        guard state.isPlaying else { return Theme.surfaceRaised }
        switch state.accentLevel {
        case .strong: return Theme.accentStrong
        case .medium: return Theme.accentMedium
        case .normal: return Theme.accentNormal
        case .weak:   return Theme.accentNormal.opacity(0.7)
        case .muted:  return Theme.surfaceRaised
        case .pickup: return Theme.accentPickup    // count-in lead-in beat — a distinct, cool colour
        }
    }

    private var centerLabel: String {
        guard state.isPlaying, let beat = activeBeat else { return "—" }
        return "\(beat + 1)"
    }
}

// MARK: - Dots

/// One dot per beat, the current beat held lit across its subdivisions; a row of subdivision pips below
/// reflects the "e / and / a" progress within the current beat.
private struct DotsIndicator: View {
    let state: BeatVisualState

    private var activeBeat: Int? { state.isPlaying ? state.currentBeat : nil }

    var body: some View {
        VStack(spacing: 22) {
            BeatDotsRow(state: state, activeBeat: activeBeat)
            if state.ticksPerBeat > 1 {
                SubdivisionPips(state: state)
            }
        }
    }
}

// MARK: - Counter

/// A single large number: the current beat, held steady across its subdivisions, pulsing on each click.
/// A subdivision-pip row under it reflects the "e / and / a" pulses.
private struct CounterIndicator: View {
    let state: BeatVisualState
    @State private var popped = false

    var body: some View {
        VStack(spacing: 12) {
            Text(bigLabel)
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(numberColor)
                .scaleEffect(popped ? 1.06 : 1.0)
                .shadow(color: numberColor.opacity(state.isPlaying ? 0.5 : 0), radius: popped ? 22 : 6)
                .animation(.easeOut(duration: 0.11), value: popped)
                .onChange(of: state.flashID) { _, _ in
                    popped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { popped = false }
                }
            Text(subLabel)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
            if state.ticksPerBeat > 1 {
                SubdivisionPips(state: state)
            }
        }
    }

    private var bigLabel: String {
        guard state.isPlaying, let b = state.currentBeat else { return "—" }
        return "\(b + 1)"
    }

    private var subLabel: String {
        guard state.isPlaying, let b = state.currentBeat else { return "READY" }
        return "BEAT \(b + 1) OF \(max(state.beatsPerMeasure, 1))"
    }

    private var numberColor: Color {
        guard state.isPlaying, let b = state.currentBeat else { return Theme.textSecondary }
        return Theme.beatColor(for: state.accent(b), isActive: true)
    }
}

// MARK: - Ring

/// A circular ring divided into `beatsPerMeasure` beats: each beat is a tick around the circle that
/// lights as it passes (current beat brightest, accented beats longer), with smaller ticks for the
/// subdivisions between beats. The centre shows the current beat number.
private struct RingIndicator: View {
    let state: BeatVisualState
    @State private var popped = false

    private let size: CGFloat = 220

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 2).frame(width: size, height: size)

            ForEach(Array(0..<max(state.beatsPerMeasure, 1)), id: \.self) { i in
                beatTick(i)
            }
            ForEach(subdivisionSlots, id: \.self) { slot in
                subdivisionTick(slot)
            }

            VStack(spacing: 2) {
                Text(centerLabel)
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(centerColor)
                    .scaleEffect(popped ? 1.08 : 1.0)
                    .animation(.easeOut(duration: 0.11), value: popped)
                Text("of \(max(state.beatsPerMeasure, 1))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: state.flashID) { _, _ in
            popped = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { popped = false }
        }
    }

    /// Global subdivision positions that are NOT on a beat (the beat positions are drawn by `beatTick`).
    private var subdivisionSlots: [Int] {
        guard state.ticksPerBeat > 1 else { return [] }
        let total = max(state.beatsPerMeasure, 1) * state.ticksPerBeat
        return Array(0..<total).filter { $0 % state.ticksPerBeat != 0 }
    }

    private func beatTick(_ i: Int) -> some View {
        let n = max(state.beatsPerMeasure, 1)
        let accented = state.isAccented(i)
        let isCurrent = state.isPlaying && state.currentBeat == i
        let passed = state.isPlaying && (state.currentBeat ?? -1) >= i
        let length: CGFloat = accented ? 26 : 18
        let width: CGFloat = isCurrent ? 8 : (accented ? 6 : 4)
        let color: Color = isCurrent
            ? (accented ? Theme.accentStrong : Theme.accentNormal)
            : (passed ? Theme.accentNormal.opacity(0.45) : Theme.beatIdle)
        return Capsule()
            .fill(color)
            .frame(width: width, height: isCurrent ? length + 6 : length)
            .offset(y: -(size / 2 - 16))
            .rotationEffect(.degrees(Double(i) / Double(n) * 360))
            .animation(.easeOut(duration: 0.08), value: state.currentBeat)
    }

    private func subdivisionTick(_ slot: Int) -> some View {
        let tpb = max(state.ticksPerBeat, 1)
        let totalSlots = max(state.beatsPerMeasure, 1) * tpb
        let beat = slot / tpb
        let lit = state.isPlaying && state.currentBeat == beat && (slot % tpb) <= state.subdivisionPhase
        return Capsule()
            .fill(lit ? Theme.accentNormal.opacity(0.8) : Theme.beatIdle.opacity(0.55))
            .frame(width: 3, height: 8)
            .offset(y: -(size / 2 - 34))
            .rotationEffect(.degrees(Double(slot) / Double(totalSlots) * 360))
            .animation(.easeOut(duration: 0.06), value: state.subdivisionPhase)
    }

    private var centerLabel: String {
        guard state.isPlaying, let b = state.currentBeat else { return "—" }
        return "\(b + 1)"
    }

    private var centerColor: Color {
        guard state.isPlaying, let b = state.currentBeat else { return Theme.textSecondary }
        return Theme.beatColor(for: state.accent(b), isActive: true)
    }
}
