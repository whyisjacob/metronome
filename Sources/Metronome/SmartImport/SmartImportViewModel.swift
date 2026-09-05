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

    /// Where the flow is: choosing a source, running OCR, reviewing the (editable) detection, or a visible
    /// failure (a picked photo that couldn't even be loaded).
    enum Stage: Equatable {
        case chooser
        case processing
        case review
        /// A picked photo could not be loaded/decoded — shown as a visible error with a retry, so a
        /// failure is never silent. (A readable-but-empty photo is a normal `.review` with a "found
        /// nothing" note, not this.)
        case failed(String)
    }

    @Published var stage: Stage = .chooser

    // Editable review fields — seeded from the detection, then freely overridable by the user.
    @Published var tempoBPM: Int = 120
    @Published var numerator: Int = 4
    @Published var denominator: Int = 4

    /// The raw detection (`nil` until OCR has run once). Drives the "what we found / found nothing" note.
    @Published private(set) var result: SheetMusicImportResult?

    /// The exact strings OCR read off the photo (in reading order), surfaced on the review screen as a
    /// "what we read" section. When parsing misses, this shows the user *why* — and what to type instead —
    /// so the result is never a blank screen with no explanation.
    @Published private(set) var recognizedText: [String] = []

    /// Tempo bounds mirror the engine's accepted range, so the review stepper can't dial in a value that
    /// would later be clamped on apply.
    let tempoRange = Int(MetronomeConfiguration.tempoRange.lowerBound)...Int(MetronomeConfiguration.tempoRange.upperBound)

    #if canImport(UIKit)
    private let recognizer: SheetMusicTextRecognizing

    init(recognizer: SheetMusicTextRecognizing = VisionSheetMusicTextRecognizer()) {
        self.recognizer = recognizer
    }

    /// Kick off OCR for a chosen image, then parse + seed the review fields. Called from the UI on the
    /// main actor; the Vision work (and image preprocessing) happens off-main inside the recognizer.
    func process(image: UIImage) {
        stage = .processing
        Task { [weak self] in
            guard let self else { return }
            let lines = await self.recognizer.recognizedLines(in: image)
            self.ingest(lines)
        }
    }
    #else
    init() {}
    #endif

    /// Parse recognised OCR lines (with geometry) and seed the editable fields (keeping current values
    /// where nothing was detected), record the raw text for the review screen, then move to the review
    /// stage. Free of Vision/UIKit, so the recognise→parse→seed path is unit-testable with canned lines.
    func ingest(_ lines: [RecognizedTextLine]) {
        recognizedText = lines.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let detection = SheetMusicOCRParser.parse(lines)
        result = detection
        if let bpm = detection.tempoBPM { tempoBPM = bpm.clamped(to: tempoRange) }
        if let ts = detection.timeSignature {
            numerator = ts.numerator
            denominator = ts.denominator
        }
        stage = .review
    }

    /// String convenience (tests / geometry-less callers): treats each string as a line with no geometry.
    func ingest(recognizedLines: [String]) {
        ingest(recognizedLines.map { RecognizedTextLine(text: $0) })
    }

    /// Reset back to the source chooser (e.g. "try another photo").
    func reset() {
        stage = .chooser
        result = nil
        recognizedText = []
    }

    /// Surface a **visible** failure when a chosen photo can't be loaded at all (e.g. an undecodable
    /// asset). This is distinct from a readable-but-empty photo, which stays a normal `.review` with a
    /// "found nothing" note — here we couldn't even get an image, so the user sees an error and a retry
    /// instead of nothing happening.
    func failedToLoadImage() {
        result = nil
        recognizedText = []
        stage = .failed("Couldn’t load that photo. Please try another.")
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
