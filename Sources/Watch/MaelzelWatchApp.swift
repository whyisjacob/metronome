import SwiftUI

@main
struct MaelzelWatchApp: App {
    @StateObject private var model = WatchMetronomeModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchMetronomeView(model: model)
                .onChange(of: phase) { _, phase in model.setForeground(phase == .active) }
        }
    }
}

struct WatchMetronomeView: View {
    @ObservedObject var model: WatchMetronomeModel
    @State private var showSettings = false
    @State private var showSound = false
    var body: some View {
        NavigationStack {
                VStack(spacing: 4) {
                    HStack {
                        Text(model.leadIn ? "Lead-in" : model.currentConfig.timeSignature.displayString)
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.currentConfig.ticksPerBeat)×")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("\(model.currentConfig.ticksPerBeat) clicks per beat")
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).accessibilityLabel("Settings")
                    }
                    .frame(height: 22)
                    if model.snapshot?.song != nil {
                        Text(model.title).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityLabel("Selected song: \(model.title)")
                    }
                    Text(model.count > 0 ? "\(model.count)" : "—")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(model.count == 1 ? Color.yellow : Color.white)
                        .accessibilityLabel("Beat \(model.count)")
                    HStack(spacing: 12) {
                        Button { model.changeTempo(model.tempoValue - 1) } label: { Image(systemName: "minus").frame(width: 34, height: 30) }
                            .accessibilityLabel("Slower")
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(model.tempoValue))").font(.title3).monospacedDigit()
                            Text(model.snapshot?.song == nil ? "BPM" : "%").font(.system(size: 9))
                        }
                        Button { model.changeTempo(model.tempoValue + 1) } label: { Image(systemName: "plus").frame(width: 34, height: 30) }
                            .accessibilityLabel("Faster")
                    }
                    .buttonStyle(.plain).disabled(model.isBusy).frame(height: 30)
                    Button { showSound = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.output.symbol)
                            Text("Sound: \(model.output.title)")
                            Image(systemName: "chevron.right").font(.system(size: 9))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sound options, \(model.output.title)")
                    Text(model.status).font(.system(size: 9)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(1).frame(height: 12)
                Button { model.toggle() } label: {
                    Label(model.isPlaying ? "Stop" : (model.isBusy ? "Cancel" : model.startTitle),
                          systemImage: model.isPlaying || model.isBusy ? "stop.fill" : "play.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .background(model.isPlaying ? Color.red : Color.green, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--watch-preview-sound") { showSound = true }
                #endif
            }
            .sheet(isPresented: $showSound) {
                WatchSoundView(model: model)
            }
            .sheet(isPresented: $showSettings) {
                Form {
                    if model.snapshot?.song != nil { Text(model.title).font(.headline) }
                    Text(model.status).font(.footnote)
                    Text("Subdivision: \(model.currentConfig.subdivision.displayName(in: model.currentConfig.timeSignature))")
                        .font(.footnote)
                    Picker("Sound", selection: Binding(get: { model.output }, set: { model.selectOutput($0) })) {
                        ForEach(WatchOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Vibration requires the watch to stay awake. watchOS controls when the display sleeps; Always On alone does not keep vibration running. Audio modes can continue when the display sleeps.")
                        .font(.footnote)
                    if model.snapshot?.song == nil {
                        Picker("Beats", selection: Binding(get: { model.currentConfig.timeSignature.numerator },
                            set: { model.changeMeter(numerator: $0, denominator: model.currentConfig.timeSignature.denominator) })) {
                            ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Note value", selection: Binding(get: { model.currentConfig.timeSignature.denominator },
                            set: { model.changeMeter(numerator: model.currentConfig.timeSignature.numerator, denominator: $0) })) {
                            ForEach(TimeSignature.allowedDenominators, id: \.self) { Text("1/\($0)").tag($0) }
                        }
                    } else { Text("Edit song sections and meter on iPhone.").font(.footnote) }
                    Button("Sync from iPhone") { model.refresh() }
                }
            }
        }
    }
}

struct WatchSoundView: View {
    @ObservedObject var model: WatchMetronomeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(WatchOutput.allCases, id: \.self) { output in
                    Button {
                        model.selectOutput(output)
                        dismiss()
                    } label: {
                        HStack {
                            Text(output.title)
                            Spacer()
                            if model.output == output { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                        .frame(minHeight: 30)
                    }
                    .accessibilityLabel(output.title + (model.output == output ? ", selected" : ""))
                }
                Text("Changing sound stops playback. Tap \(model.startTitle) to play with your selection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Sound")
        }
    }
}
