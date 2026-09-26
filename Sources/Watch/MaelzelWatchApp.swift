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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    HStack {
                        Text(model.leadIn ? "Lead-in" : model.currentConfig.timeSignature.displayString)
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).accessibilityLabel("Settings")
                    }
                    Text(model.count > 0 ? "\(model.count)" : "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.6)
                        .foregroundStyle(model.count == 1 ? Color.yellow : Color.white)
                        .accessibilityLabel("Beat \(model.count)")
                    HStack(spacing: 12) {
                        Button { model.changeTempo(model.tempoValue - 1) } label: { Image(systemName: "minus") }
                            .accessibilityLabel("Slower")
                        VStack(spacing: 0) {
                            Text("\(Int(model.tempoValue))").font(.title3).monospacedDigit()
                            Text(model.tempoUnit).font(.system(size: 10))
                        }
                        Button { model.changeTempo(model.tempoValue + 1) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Faster")
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { model.toggle() } label: {
                    Label(model.isPlaying ? "Stop" : (model.isBusy ? "Cancel" : "Start"),
                          systemImage: model.isPlaying || model.isBusy ? "stop.fill" : "play.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(model.isPlaying ? .red : .green)
                .background(.black)
            }
            .sheet(isPresented: $showSettings) {
                Form {
                    if model.snapshot?.song != nil { Text(model.title).font(.headline) }
                    Picker("Beat output", selection: $model.output) {
                        ForEach(WatchOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(model.isPlaying)
                    Text("Vibration works while Maelzel is visible. Spoken counting uses your watch’s audio output.")
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
