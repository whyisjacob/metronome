import Foundation
import CoreGraphics

/// One line of recognized text together with its geometry. `boundingBox` is Vision's normalized rect —
/// origin at the image's **bottom-left**, axes in 0…1 — which lets the parser reason about *layout* (a
/// vertically **stacked** time signature has its numerator box directly above its denominator box) without
/// any Vision/UIKit dependency, so the parser stays a pure, testable value type. A geometry-less line
/// (`boundingBox == .zero`, the default) still runs every text-based rule; only the stacked-geometry rule
/// needs real boxes.
struct RecognizedTextLine: Equatable {
    var text: String
    var boundingBox: CGRect

    init(text: String, boundingBox: CGRect = .zero) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

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

/// Turns the strings (and, when available, their bounding boxes) that on-device OCR (Vision) recognised on
/// a photo of a score into a `SheetMusicImportResult`. **Pure and deterministic**: no I/O, no image, no
/// Vision types — so the whole extraction is unit-testable in CI with hand-written sample inputs (e.g.
/// `["♩ = 132"]` → 132 BPM, or two vertically stacked digit boxes → their meter).
///
/// Everything here is best-effort. OCR of stacked time-signature numerals and tiny tempo glyphs is
/// imperfect, so a miss returns `nil` for that field rather than guessing wildly; the review UI always
/// lets the user see the raw recognised text and correct or fill in what was (or wasn't) found.
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

    /// Numerators a real time signature can carry (matches `TimeSignature.numeratorRange`).
    private static let numeratorRange = 1...32

    // MARK: - Entry points

    /// Parse recognised OCR lines **with geometry** (the real, on-device path) into a best-effort tempo +
    /// time signature. Geometry lets us recognise a *stacked* time signature (numerator over denominator,
    /// no slash) — the shape real scores actually print.
    static func parse(_ lines: [RecognizedTextLine]) -> SheetMusicImportResult {
        var result = SheetMusicImportResult()
        let strings = lines.map(\.text)

        // Tempo: prefer an explicit numeric metronome mark; only fall back to an Italian word if there's
        // no number anywhere (the spec's "prefer an explicit number").
        if let bpm = detectNumericTempo(in: strings) {
            result.tempoBPM = bpm
        } else if let match = detectTempoWord(in: strings) {
            result.tempoBPM = match.bpm
            result.tempoWord = match.word
        }

        result.timeSignature = detectTimeSignature(lines)
        return result
    }

    /// String convenience (tests / geometry-less callers): treats each string as a line with no geometry,
    /// so the stacked-**geometry** rule is skipped but every text rule (slash, symbols, fused digits,
    /// tempo) still applies.
    static func parse(recognizedLines strings: [String]) -> SheetMusicImportResult {
        parse(strings.map { RecognizedTextLine(text: $0) })
    }

    // MARK: - Tempo detection

    /// The first plausible numeric metronome mark, scanning lines in reading order. Deliberately tolerant
    /// of how OCR mangles a score's beat glyph: the quarter-note "♩" is very often read as **"J"**, **"q"**,
    /// a box, or dropped entirely. So we accept a note glyph (♩ ♪ ♫ ♬), the letters J/q, or the word
    /// "quarter [note]", each optionally followed by "=", then the BPM — and, as a catch-all, any number
    /// right after an "=" (the equals is the strongest signal even when the glyph is lost).
    private static func detectNumericTempo(in lines: [String]) -> Int? {
        for line in lines {
            // Beat-unit token (glyph / "J" / "q" / "quarter [note]") + optional "=" + number.
            // Covers "♩ = 120", "J = 120", "q=132", "quarter note = 96", and a bare "♩ 96".
            if let n = firstNumber(#"(?:[\x{2669}-\x{266C}]|(?<![A-Za-z])[Jq](?![A-Za-z])|quarter(?:\s*note)?)\s*=?\s*([0-9]{1,3})"#,
                                   in: line, options: .caseInsensitive), plausibleBPM.contains(n) {
                return n
            }
            // A number right after an equals sign — the overwhelmingly common mark, even if the glyph was
            // OCR'd away ("= 120", "M.M. = 88").
            if let n = firstNumber(#"=\s*([0-9]{1,3})"#, in: line), plausibleBPM.contains(n) {
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

    /// Detect a time signature, most-reliable rule first:
    ///   1. an explicit "N/M" slash;
    ///   2. a **stacked** meter — a numerator digit box directly above a denominator digit box (the real,
    ///      no-slash shape on a score), using the lines' geometry;
    ///   3. cut time (¢ / 𝄵 / "cut time");
    ///   4. common time (a lone "C" / 𝄴 / "common time");
    ///   5. a stack OCR'd as a single all-digit token ("44" → 4/4, "68" → 6/8, "916" → 9/16) — last, since
    ///      it is the most guess-y.
    private static func detectTimeSignature(_ lines: [RecognizedTextLine]) -> TimeSignature? {
        let strings = lines.map(\.text)
        let joined = strings.joined(separator: "\n")

        if let ts = detectSlashMeter(in: strings) { return ts }
        if let ts = detectStackedMeter(lines) { return ts }
        if isCutTime(joined) { return TimeSignature(numerator: 2, denominator: 2) }
        if isCommonTime(strings: strings, joined: joined) { return TimeSignature(numerator: 4, denominator: 4) }
        if let ts = detectFusedDigitMeter(in: strings) { return ts }
        return nil
    }

    /// An explicit "N/M" (e.g. 4/4, 3/4, 6/8, 12/8). Only accept a musical denominator so a stray fraction
    /// or date fragment isn't mistaken for a meter.
    private static func detectSlashMeter(in lines: [String]) -> TimeSignature? {
        for line in lines {
            guard let groups = firstMatch(#"([0-9]{1,2})\s*/\s*([0-9]{1,2})"#, in: line),
                  let num = Int(groups[1]), let den = Int(groups[2]) else { continue }
            if allowedDenominators.contains(den), numeratorRange.contains(num) {
                return TimeSignature(numerator: num, denominator: den)
            }
        }
        return nil
    }

    /// A **stacked** time signature detected from geometry: a single-number box (the numerator, 1–32)
    /// sitting directly **above** another single-number box (the denominator, one of 2/4/8/16), their
    /// centres horizontally aligned. Vision boxes use a bottom-left origin, so "above" means a larger
    /// `midY`. Among all valid pairs we take the tightest-aligned, left-most one (a meter sits at the start
    /// of the staff). Returns `nil` when no line carries geometry (the string-only path) or nothing lines
    /// up — real scores stack the numerals with no slash, which the text rules alone can never catch.
    private static func detectStackedMeter(_ lines: [RecognizedTextLine]) -> TimeSignature? {
        let numerics: [(value: Int, box: CGRect)] = lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = line.boundingBox
            guard !box.isNull, box.width > 0, box.height > 0, let value = Int(text) else { return nil }
            return (value: value, box: box)
        }
        guard numerics.count >= 2 else { return nil }

        var best: (num: Int, den: Int, score: CGFloat)?
        for top in numerics where numeratorRange.contains(top.value) {
            for bottom in numerics where allowedDenominators.contains(bottom.value) {
                guard top.box != bottom.box else { continue }
                // Numerator must be physically higher (larger midY in Vision's bottom-left space).
                guard top.box.midY > bottom.box.midY else { continue }
                // Centres horizontally aligned → stacked, not side-by-side.
                let avgW = max((top.box.width + bottom.box.width) / 2, 0.0001)
                let dx = abs(top.box.midX - bottom.box.midX)
                guard dx <= avgW * 1.25 else { continue }
                // Vertically adjacent → a small gap relative to the digits' heights (not opposite ends of
                // the page).
                let avgH = max((top.box.height + bottom.box.height) / 2, 0.0001)
                let gap = top.box.minY - bottom.box.maxY
                guard gap <= avgH * 1.75 else { continue }
                // Prefer tight alignment, small gap, and a left-of-staff position.
                let score = dx + max(gap, 0) + top.box.midX * 0.5
                if best == nil || score < best!.score { best = (num: top.value, den: bottom.value, score: score) }
            }
        }
        if let best { return TimeSignature(numerator: best.num, denominator: best.den) }
        return nil
    }

    /// Cut time: the ¢ cent sign (the usual OCR of 𝄵), the cedi sign (another frequent misread), the actual
    /// cut-time glyph, or the words.
    private static func isCutTime(_ joined: String) -> Bool {
        joined.contains("\u{00A2}")           // ¢  CENT SIGN
            || joined.contains("\u{20B5}")     // ₵  CEDI SIGN
            || joined.contains("\u{1D135}")    // 𝄵 MUSICAL SYMBOL CUT TIME
            || firstMatch(#"cut[\s-]?time"#, in: joined, options: .caseInsensitive) != nil
    }

    /// Common time: a standalone "C", the common-time glyph, or the words.
    private static func isCommonTime(strings lines: [String], joined: String) -> Bool {
        lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "C" })
            || joined.contains("\u{1D134}")    // 𝄴 MUSICAL SYMBOL COMMON TIME
            || firstMatch(#"common[\s-]?time"#, in: joined, options: .caseInsensitive) != nil
    }

    /// A stacked meter that OCR fused into a single all-digit token ("4 4"/"44" → 4/4, "68" → 6/8,
    /// "916" → 9/16, "128" → 12/8). Conservative on purpose to avoid eating opus/measure numbers: it only
    /// considers a line that is **entirely** digits (ignoring internal spaces), 2–4 characters, and only
    /// accepts a split into a valid numerator (1–32) over a musical denominator. A "16" suffix is tried
    /// first, then a single trailing 2/4/8 — so e.g. "120" (ends in 0) yields nothing.
    private static func detectFusedDigitMeter(in lines: [String]) -> TimeSignature? {
        for line in lines {
            let digits = line.filter { !$0.isWhitespace }
            guard (2...4).contains(digits.count), digits.allSatisfy(\.isNumber) else { continue }
            if digits.hasSuffix("16"), let num = Int(digits.dropLast(2)), numeratorRange.contains(num) {
                return TimeSignature(numerator: num, denominator: 16)
            }
            if let last = digits.last, let den = Int(String(last)), [2, 4, 8].contains(den),
               let num = Int(digits.dropLast()), numeratorRange.contains(num) {
                return TimeSignature(numerator: num, denominator: den)
            }
        }
        return nil
    }

    // MARK: - Regex helpers

    /// The integer in capture group 1 of the first match of `pattern` in `text`, or `nil`.
    private static func firstNumber(_ pattern: String, in text: String,
                                    options: NSRegularExpression.Options = []) -> Int? {
        guard let groups = firstMatch(pattern, in: text, options: options), groups.count > 1 else { return nil }
        return Int(groups[1])
    }

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
