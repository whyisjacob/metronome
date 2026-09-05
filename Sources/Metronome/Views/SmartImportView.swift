import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The "Smart Import" sheet: photograph or pick an image of sheet music, read its **starting** tempo and
/// time signature on-device with Vision OCR, then review/edit the detection and apply it to the metronome
/// (or save it as a new song). Nothing is auto-applied — the user always confirms.
///
/// Scope is stated honestly in the UI: v1 reads the starting tempo + time signature only. Bar counting
/// and mid-piece meter changes are a later stretch (see ROADMAP).
struct SmartImportView: View {
    @ObservedObject var metronome: MetronomeViewModel
    @ObservedObject var store: SongStore

    @StateObject private var vm = SmartImportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var savedSongName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        switch vm.stage {
                        case .chooser:       chooser
                        case .processing:    processing
                        case .review:        review
                        case .failed(let m): failure(m)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                savedBanner
            }
            .foregroundStyle(Theme.textPrimary)
            .navigationTitle("Smart Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // PHPicker needs no permission; the camera uses NSCameraUsageDescription (see project.yml). This
        // view owns dismissal — it flips the presenting binding when the picker finishes — so dismissal is
        // deterministic and never depends on `@Environment(\.dismiss)` inside the picker (see PhotoPickers).
        .sheet(isPresented: $showLibrary) {
            PhotoLibraryPicker { result in
                showLibrary = false
                handlePick(result)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { result in
                showCamera = false
                handlePick(result)
            }
            .ignoresSafeArea()
        }
    }

    /// React to a finished pick: OCR the chosen image, ignore a plain cancel, or surface a visible error on
    /// a load failure — so a failure is never silent.
    private func handlePick(_ result: ImagePickResult) {
        switch result {
        case .picked(let image): vm.process(image: image)
        case .cancelled:         break   // user backed out — stay on the chooser
        case .failed:            vm.failedToLoadImage()
        }
    }

    // MARK: - Stage: choose a source

    private var chooser: some View {
        VStack(spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("On-device — nothing leaves your phone", systemImage: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Take or choose a photo of your sheet music. Maelzel reads the **starting tempo** and **time signature** right on your device with Apple’s Vision text recognition — no network, no cloud.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textPrimary)
                    Text("v1 reads the starting tempo + time signature only. Counting bars and mid-piece meter changes are coming later.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            #if canImport(UIKit)
            if CameraPicker.isAvailable {
                importButton(title: "Take a photo", systemImage: "camera.fill") { showCamera = true }
            }
            #endif
            importButton(title: "Choose from library", systemImage: "photo.on.rectangle") { showLibrary = true }
        }
    }

    private func importButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(SelectableStyle(isOn: true))
    }

    // MARK: - Stage: processing

    private var processing: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accentNormal)
            Text("Reading the music…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Stage: failure (visible, never silent)

    private func failure(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.stop)
            Text(message)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
            Button { vm.reset() } label: {
                Text("Try again").frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(SelectableStyle(isOn: true))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.top, 20)
    }

    // MARK: - Stage: review & confirm

    private var review: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: vm.foundSomething ? "text.viewfinder" : "exclamationmark.magnifyingglass")
                    .foregroundStyle(vm.foundSomething ? Theme.start : Theme.accentMedium)
                Text(vm.detectionSummary)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            tempoCard
            timeSignatureCard

            VStack(spacing: 10) {
                Button { apply() } label: {
                    Text("Apply to metronome").frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(SelectableStyle(isOn: true))

                Button { saveAsSong() } label: {
                    Label("Save as a new song", systemImage: "bookmark")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(PillButtonStyle())

                Button { vm.reset() } label: {
                    Text("Use another photo")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var tempoCard: some View {
        Card("Tempo") {
            HStack {
                TextField("Tempo", value: $vm.tempoBPM, format: .number)
                    .keyboardType(.numberPad)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 96)
                Text("BPM")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Stepper("Tempo", value: $vm.tempoBPM, in: vm.tempoRange)
                    .labelsHidden()
            }
        }
    }

    private var timeSignatureCard: some View {
        Card("Time signature") {
            HStack {
                Text(vm.timeSignature.displayString)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Stepper("Beats per bar",
                        value: $vm.numerator,
                        in: TimeSignature.numeratorRange)
                    .labelsHidden()
            }
            HStack(spacing: 8) {
                ForEach(TimeSignature.allowedDenominators, id: \.self) { denom in
                    Button { vm.denominator = denom } label: {
                        Text("\(denom)").frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(SelectableStyle(isOn: vm.denominator == denom))
                }
            }
        }
    }

    // MARK: - Confirmation banner

    @ViewBuilder private var savedBanner: some View {
        if let name = savedSongName {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.start)
                    Text("Saved “\(name)” to Songs")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
                .padding(.bottom, 28)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    /// Applies the confirmed tempo + time signature to the live metronome. `setBPM` clamps to the engine's
    /// range; the two meter setters together install `TimeSignature(numerator, denominator)` with its
    /// default accents.
    private func apply() {
        applyToMetronome()
        dismiss()
    }

    private func applyToMetronome() {
        metronome.setBPM(Double(vm.tempoBPM))
        metronome.setNumerator(vm.numerator)
        metronome.setDenominator(vm.denominator)
    }

    /// Applies to the metronome and also seeds a new one-section song from the confirmed values, so the
    /// import can become the start of a tempo-map draft in the Songs library.
    private func saveAsSong() {
        applyToMetronome()
        let config = MetronomeConfiguration(bpm: Double(vm.tempoBPM), timeSignature: vm.timeSignature)
        let name = "\(vm.tempoBPM) BPM · \(vm.timeSignature.displayString)"
        store.upsert(Song(fromCurrentSettings: config, name: name))
        withAnimation(.easeInOut(duration: 0.2)) { savedSongName = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { dismiss() }
    }
}
