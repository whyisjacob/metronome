import Foundation

/// The best-effort result of reading sheet-music metadata off a photo: a **starting** tempo and/or a
/// time signature. Both are optional — OCR is imperfect and a given photo may reveal only one (or
/// neither). This is a plain value type with no Vision/UIKit dependency, so the parsing that produces it
/// (`SheetMusicOCRParser.parse`) is a pure function that unit-tests without a camera or a real image.
///
/// HONEST SCOPE (v1): only the *starting* tempo and time signature are extracted. Bar counting and
/// mid-piece meter/tempo changes are deliberately out (a documented stretch on the roadmap).
struct SheetMusicImportResult: Equatable {
    /// Detected starting tempo in BPM, if any. Taken from an explicit metronome mark ("♩ = 120") when one
    /// is present; otherwise mapped from an Italian tempo word ("Allegro" → 140).
    var tempoBPM: Int?
    /// The Italian tempo word the BPM was mapped from, when `tempoBPM` came from a *word* rather than an
    /// explicit number (so the review UI can say "Allegro → 140"). `nil` when the tempo was an explicit
    /// number, or when no tempo was found.
    var tempoWord: String?
    /// Detected time signature, if any.
    var timeSignature: TimeSignature?

    /// Whether anything at all was detected — drives the "nothing found, enter it yourself" message.
    var hasAnyDetection: Bool { tempoBPM != nil || timeSignature != nil }

    static let empty = SheetMusicImportResult()
}

/// Turns the strings that on-device OCR (Vision) recognised on a photo of a score into a
/// `SheetMusicImportResult`. **Pure and deterministic**: `parse(recognizedLines:)` takes an array of
/// recognised text lines and returns the detection — no I/O, no image, no Vision types — so the whole
/// extraction is unit-testable in CI with hand-written sample inputs (e.g. `["♩ = 132"]` → 132 BPM).
///
/// Everything here is best-effort. OCR of stacked time-signature numerals and tiny tempo glyphs is
/// imperfect, so a miss returns `nil` for that field rather than guessing wildly; the review UI always
/// lets the user correct or fill in what was (or wasn't) found.
enum SheetMusicOCRParser {

    // MARK: - Tempo vocabulary

    /// Italian tempo words → a representative BPM. The seven the product spec calls out are the canonical
    /// teaching values; the remainder are common neighbours so more marks resolve to something sensible.
    /// Used **only** when no explicit numeric metronome mark is found — a number always wins.
    static let tempoWordBPM: [String: Int] = [
        // The seven canonical marks.
        "largo": 50, "adagio": 70, "andante": 92, "moderato": 114,
        "allegro": 140, "vivace": 168, "presto": 184,
        // Common neighbours (purely additive; these never override the seven above).
        "grave": 40, "lento": 52, "larghetto": 63, "adagietto": 75,
        "andantino": 96, "allegretto": 116, "vivo": 160, "prestissimo": 200,
    ]

    /// Plausible BPM window for a *numeric* metronome mark. Filters out page numbers, opus numbers, and
    /// stray digits. (A detected value is still re-clamped to the engine's 30…300 range when applied.)
    private static let plausibleBPM = 20...400

    /// Denominators a real time signature can carry (matches `TimeSignature.allowedDenominators`); a
    /// slash-number whose denominator isn't one of these is treated as noise, not a meter.
    private static let allowedDenominators: Set<Int> = [2, 4, 8, 16]

    // MARK: - Entry point

    /// Parse recognised OCR lines (top-to-bottom reading order) into a best-effort tempo + time signature.
    static func parse(recognizedLines lines: [String]) -> SheetMusicImportResult {
        var result = SheetMusicImportResult()
        let joined = lines.joined(separator: "\n")

        // Tempo: prefer an explicit numeric metronome mark; only fall back to an Italian word if there's
        // no number anywhere (the spec's "prefer an explicit number").
        if let bpm = detectNumericTempo(in: lines) {
            result.tempoBPM = bpm
        } else if let match = detectTempoWord(in: lines) {
            result.tempoBPM = match.bpm
            result.tempoWord = match.word
        }

        // Time signature: prefer an explicit "N/M", then common/cut-time symbols or words.
        result.timeSignature = detectTimeSignature(in: lines, joined: joined)

        return result
    }

    // MARK: - Tempo detection

    /// The first plausible numeric metronome mark, scanning lines in reading order. Handles "♩ = 120",
    /// "♩=120", "= 120", "M.M. = 120" (via the `=`), and a bare "♩ 120" (glyph directly before a number).
    private static func detectNumericTempo(in lines: [String]) -> Int? {
        for line in lines {
            // A number after an equals sign — the overwhelmingly common form of a metronome mark.
            if let groups = firstMatch(#"=\s*([0-9]{1,3})"#, in: line),
               let n = Int(groups[1]), plausibleBPM.contains(n) {
                return n
            }
            // A note glyph (♩ ♪ ♫ ♬) directly followed by a number, no equals sign.
            if let groups = firstMatch(#"[\x{2669}-\x{266C}]\s*([0-9]{1,3})"#, in: line),
               let n = Int(groups[1]), plausibleBPM.contains(n) {
                return n
            }
        }
        return nil
    }

    /// The first Italian tempo word found in reading order, with its representative BPM. Tokenises on
    /// non-letters so trailing punctuation ("Allegro,") and surrounding words ("Allegro con brio") don't
    /// hide the match.
    private static func detectTempoWord(in lines: [String]) -> (word: String, bpm: Int)? {
        let tokens = lines.joined(separator: " ").components(separatedBy: CharacterSet.letters.inverted)
        for token in tokens where !token.isEmpty {
            if let bpm = tempoWordBPM[token.lowercased()] {
                return (token.lowercased().capitalized, bpm)
            }
        }
        return nil
    }

    // MARK: - Time-signature detection

    private static func detectTimeSignature(in lines: [String], joined: String) -> TimeSignature? {
        // 1) An explicit "N/M" (e.g. 4/4, 3/4, 6/8, 12/8). Only accept a musical denominator so a stray
        //    fraction or date fragment isn't mistaken for a meter.
        for line in lines {
            guard let groups = firstMatch(#"([0-9]{1,2})\s*/\s*([0-9]{1,2})"#, in: line),
                  let num = Int(groups[1]), let den = Int(groups[2]) else { continue }
            if allowedDenominators.contains(den), (1...32).contains(num) {
                return TimeSignature(numerator: num, denominator: den)
            }
        }

        // 2) Cut time: the ¢ cent sign (the usual OCR of 𝄵), the actual cut-time glyph, or the words.
        if joined.contains("\u{00A2}")           // ¢  CENT SIGN
            || joined.contains("\u{20B5}")        // ₵  CEDI SIGN (another frequent misread)
            || joined.contains("\u{1D135}")       // 𝄵 MUSICAL SYMBOL CUT TIME
            || firstMatch(#"cut[\s-]?time"#, in: joined, options: .caseInsensitive) != nil {
            return TimeSignature(numerator: 2, denominator: 2)
        }

        // 3) Common time: a standalone "C", the common-time glyph, or the words.
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "C" })
            || joined.contains("\u{1D134}")       // 𝄴 MUSICAL SYMBOL COMMON TIME
            || firstMatch(#"common[\s-]?time"#, in: joined, options: .caseInsensitive) != nil {
            return TimeSignature(numerator: 4, denominator: 4)
        }

        return nil
    }

    // MARK: - Regex helper

    /// Returns the capture groups of the first match of `pattern` in `text` (group 0 = whole match), or
    /// `nil` if there is no match. Compiles defensively — a malformed pattern yields `nil` rather than a
    /// crash — though every pattern here is a compile-time constant.
    private static func firstMatch(_ pattern: String,
                                   in text: String,
                                   options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            guard let r = Range(match.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }
}
