#if canImport(Vision) && canImport(UIKit)
import Vision
import UIKit
import ImageIO   // CGImagePropertyOrientation

/// Abstraction over "run OCR on this image and give me the recognised text lines". Lets the SmartImport
/// view model be exercised with a stub in tests while using the real Vision implementation on device.
protocol SheetMusicTextRecognizing {
    /// Recognise text in `image`, returning the best candidate string for each detected line, in reading
    /// order. Returns an empty array on failure — a blank or blurry photo is a normal outcome the review
    /// UI handles, not an error to throw.
    func recognizedText(in image: UIImage) async -> [String]
}

/// On-device OCR with Apple's **Vision** framework (`VNRecognizeTextRequest`, `.accurate` level).
/// Entirely on-device — **no network, no cloud** — so it is private and works offline.
///
/// Two deliberate settings for sheet music:
///   * `usesLanguageCorrection = false` — tempo marks, note glyphs and time-signature numerals are not
///     natural language; correction otherwise "fixes" them into words and loses the number/glyph.
///   * a low `minimumTextHeight` — tempo glyphs sit small above the staff and would otherwise be skipped.
///
/// The recognised strings are handed to the pure `SheetMusicOCRParser`; this type does no parsing itself.
struct VisionSheetMusicTextRecognizer: SheetMusicTextRecognizing {

    func recognizedText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = Self.cgOrientation(from: image.imageOrientation)

        return await withCheckedContinuation { continuation in
            // Vision is CPU/Neural-Engine work — keep it off the main actor.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.01

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Map UIKit's image orientation to the `CGImagePropertyOrientation` Vision expects, so a photo shot
    /// in any device orientation is read right-way-up.
    private static func cgOrientation(from ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
#endif
