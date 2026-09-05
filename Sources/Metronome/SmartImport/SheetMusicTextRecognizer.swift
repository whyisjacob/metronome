#if canImport(Vision) && canImport(UIKit)
import Vision
import UIKit
import CoreImage
import ImageIO   // CGImagePropertyOrientation

/// Abstraction over "run OCR on this image and give me the recognised text lines **with their geometry**".
/// Lets the SmartImport view model be exercised with a stub in tests while using the real Vision
/// implementation on device. Geometry (each line's bounding box) is what lets the parser recognise a
/// vertically **stacked** time signature (numerator over denominator, no slash) — the shape real scores
/// print.
protocol SheetMusicTextRecognizing {
    /// Recognise text in `image`, returning each detected line's best candidate string **and** its
    /// normalized bounding box, in reading order. Returns an empty array on failure — a blank or blurry
    /// photo is a normal outcome the review UI handles, not an error to throw.
    func recognizedLines(in image: UIImage) async -> [RecognizedTextLine]
}

/// On-device OCR with Apple's **Vision** framework (`VNRecognizeTextRequest`, `.accurate` level).
/// Entirely on-device — **no network, no cloud** — so it is private and works offline.
///
/// Two deliberate settings for sheet music:
///   * `usesLanguageCorrection = false` — tempo marks, note glyphs and time-signature numerals are not
///     natural language; correction otherwise "fixes" them into words and loses the number/glyph.
///   * a low `minimumTextHeight` — tempo glyphs and stacked meter numerals sit small and would otherwise
///     be skipped.
///
/// Before OCR the photo is **preprocessed** — orientation baked in, upscaled if small, and contrast
/// boosted (desaturated) — so faint, small print (exactly what a tempo mark and a time signature are)
/// recognises far better. The recognised strings + boxes are handed to the pure `SheetMusicOCRParser`;
/// this type does no parsing itself.
struct VisionSheetMusicTextRecognizer: SheetMusicTextRecognizing {

    func recognizedLines(in image: UIImage) async -> [RecognizedTextLine] {
        await withCheckedContinuation { continuation in
            // Preprocessing (redraw + Core Image) and Vision are CPU/Neural-Engine work — keep it all off
            // the main actor so the UI's "Reading the music…" spinner stays smooth.
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = Self.preprocessed(image)
                guard let cgImage = prepared.cgImage else {
                    continuation.resume(returning: [])
                    return
                }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.01

                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: prepared.orientation, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let lines: [RecognizedTextLine] = observations.compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        return RecognizedTextLine(text: candidate.string, boundingBox: obs.boundingBox)
                    }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Preprocessing

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Produce an OCR-friendly `CGImage`: orientation baked in (so we can pass `.up` to Vision), small
    /// photos upscaled so tiny glyphs are large enough to recognise, and contrast boosted + desaturated so
    /// dark print separates cleanly from paper. Falls back to the raw `cgImage` (with its real orientation)
    /// if any step can't run.
    private static func preprocessed(_ image: UIImage) -> (cgImage: CGImage?, orientation: CGImagePropertyOrientation) {
        guard image.size.width > 0, image.size.height > 0 else {
            return (cgImage: image.cgImage, orientation: cgOrientation(from: image.imageOrientation))
        }

        // Upscale up to 4× toward a ~2200px long edge; never downscale (that would lose detail).
        let longEdge = max(image.size.width, image.size.height)
        let scale = min(max(2200 / longEdge, 1), 4)
        let newSize = CGSize(width: (image.size.width * scale).rounded(),
                             height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        // Drawing the UIImage respects its orientation, so the result is upright → pass `.up` to Vision.
        let rendered = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        guard let base = rendered.cgImage else {
            return (cgImage: image.cgImage, orientation: cgOrientation(from: image.imageOrientation))
        }
        return (cgImage: contrastEnhanced(base) ?? base, orientation: .up)
    }

    /// Boost contrast and desaturate to grayscale so faint/small print stands out for OCR.
    private static func contrastEnhanced(_ cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(1.35, forKey: kCIInputContrastKey)   // >1 increases contrast
        filter.setValue(0.02, forKey: kCIInputBrightnessKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)  // desaturate → cleaner text edges
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    /// Map UIKit's image orientation to the `CGImagePropertyOrientation` Vision expects, so a photo shot
    /// in any device orientation is read right-way-up (used only on the fallback path — the preprocessed
    /// path bakes orientation into an upright image).
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
