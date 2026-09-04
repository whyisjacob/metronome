import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Drives the "Smart Import" flow: pick a photo (camera or library) → recognise text on-device with
/// Vision → parse a best-effort **starting** tempo + time signature → let the user review/edit → apply.
///
/// The parsing itself is the pure `SheetMusicOCRParser`; this view model only orchestrates the stages and
/// holds the editable review fields. It **never auto-applies** — applying to the metronome (or saving a
/// song) is always an explicit action in the view.
@MainActor
final class SmartImportViewModel: ObservableObject {

    /// Where the flow is: choosing a source, running OCR, or reviewing the (editable) detection.
    enum Stage: Equatable {
        case chooser
        case processing
        case review
    }

    @Published var stage: Stage = .chooser

    // Editable review fields — seeded from the detection, then freely overridable by the user.
    @Published var tempoBPM: Int = 120
    @Published var numerator: Int = 4
    @Published var denominator: Int = 4

    /// The raw detection (`nil` until OCR has run once). Drives the "what we found / found nothing" note.
    @Published private(set) var result: SheetMusicImportResult?

    /// Tempo bounds mirror the engine's accepted range, so the review stepper can't dial in a value that
    /// would later be clamped on apply.
    let tempoRange = Int(MetronomeConfiguration.tempoRange.lowerBound)...Int(MetronomeConfiguration.tempoRange.upperBound)

    #if canImport(UIKit)
    private let recognizer: SheetMusicTextRecognizing

    init(recognizer: SheetMusicTextRecognizing = VisionSheetMusicTextRecognizer()) {
        self.recognizer = recognizer
    }

    /// Kick off OCR for a chosen image, then parse + seed the review fields. Called from the UI on the
    /// main actor; the Vision work happens off-main inside the recognizer.
    func process(image: UIImage) {
        stage = .processing
        Task { [weak self] in
            guard let self else { return }
            let lines = await self.recognizer.recognizedText(in: image)
            self.ingest(recognizedLines: lines)
        }
    }
    #else
    init() {}
    #endif

    /// Parse recognised OCR lines and seed the editable fields (keeping current values where nothing was
    /// detected), then move to the review stage. Deliberately free of Vision/UIKit and split out from
    /// `process(image:)`, so the recognise→parse→seed path is unit-testable with canned strings.
    func ingest(recognizedLines: [String]) {
        let detection = SheetMusicOCRParser.parse(recognizedLines: recognizedLines)
        result = detection
        if let bpm = detection.tempoBPM { tempoBPM = bpm.clamped(to: tempoRange) }
        if let ts = detection.timeSignature {
            numerator = ts.numerator
            denominator = ts.denominator
        }
        stage = .review
    }

    /// Reset back to the source chooser (e.g. "try another photo").
    func reset() {
        stage = .chooser
        result = nil
    }

    /// The confirmed time signature built from the (possibly edited) review fields. Runs through the
    /// validating `TimeSignature` initializer, so numerator/denominator are always in range.
    var timeSignature: TimeSignature { TimeSignature(numerator: numerator, denominator: denominator) }

    /// Whether OCR found anything at all — the review screen shows a "fill it in yourself" note if not.
    var foundSomething: Bool { result?.hasAnyDetection ?? false }

    /// A short, human summary of what OCR found (or didn't), for the review screen.
    var detectionSummary: String {
        guard let result else { return "" }
        guard result.hasAnyDetection else {
            return "Couldn’t read a tempo or time signature from this photo — enter them below."
        }
        var parts: [String] = []
        if let word = result.tempoWord, let bpm = result.tempoBPM {
            parts.append("tempo “\(word)” → \(bpm) BPM")
        } else if let bpm = result.tempoBPM {
            parts.append("tempo \(bpm) BPM")
        }
        if let ts = result.timeSignature {
            parts.append("time signature \(ts.displayString)")
        }
        return "Detected " + parts.joined(separator: " · ") + ". Check and adjust below."
    }
}
