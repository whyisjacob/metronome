import Foundation
import CoreGraphics

/// One line of recognized text together with its geometry. `boundingBox` is Vision's normalized rect —
/// origin at the image's **bottom-left**, axes in 0…1 — which lets the parser reason about *layout* (a
/// tempo mark sits high on the page; a vertically **stacked** time signature has its numerator box directly
/// above its denominator box at the start of the first system) without any Vision/UIKit dependency, so the
/// parser stays a pure, testable value type. A geometry-less line (`boundingBox == .zero`, the default)
/// still runs every text-based rule; only the position-aware rules (stacked geometry, top-region tempo
/// ranking) need real boxes.
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
    /// Detected starting tempo in BPM, if any. Taken from the highest-ranked metronome mark ("♩ = 120")
    /// when one is present; otherwise mapped from an Italian tempo word ("Allegro" → 140).
    var tempoBPM: Int?
    /// The Italian tempo word the BPM was mapped from, when `tempoBPM` came from a *word* rather than an
    /// explicit number (so the review UI can say "Allegro → 140"). `nil` when the tempo was an explicit
    /// number, or when no tempo was found.
    var tempoWord: String?
    /// A plausible **runner-up** tempo the ranking also saw (e.g. a second metronome number on the page),
    /// distinct from `tempoBPM`. The review UI offers it as a one-tap alternative so a wrong pick is easy to
    /// correct. `nil` when there was no distinct second candidate.
    var tempoAlternativeBPM: Int?
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
/// Real scores are noisy: a title, composer, measure numbers, fingerings, lyrics, dynamics, a copyright
/// year and page numbers all read as text too. The parser stays out of that "random crap" by being
/// **contextual and spatial** rather than grabbing the first number it sees:
///   * a number only counts as a **tempo** when it is part of a tempo *expression* — next to "=", a beat
///     glyph (♩/J/quarter) or an Italian tempo word — and it is then *ranked* by how tempo-like its value
///     and page position are (marks sit high, usually top-left). A bare "5" (measure), "2026" (copyright)
///     or "3" (fingering) with no tempo context is never chosen.
///   * a **time signature** is preferentially a vertically *stacked* digit pair at the **left of the first
///     (top) system**; stacked-looking digits elsewhere (fingerings, tuplet numbers) are ranked out.
///
/// Everything here is best-effort; a miss returns `nil` for that field rather than guessing wildly, and the
/// review UI always shows the raw recognised text plus the chosen values so the user can correct them.
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

    /// Widest BPM a *numeric* mark may carry to be accepted at all — filters page/opus/year numbers while
    /// still admitting an explicit, if extreme, "♩ = 400" (which the engine later clamps to its 30…300).
    private static let acceptableBPM = 20...400

    /// The *plausible* teaching-tempo band. A value inside it is preferred when ranking; a value outside it
    /// (but still within `acceptableBPM`) is only chosen when nothing plausible competes.
    private static let plausibleBPM = 30...300

    /// Denominators a real time signature can carry (matches `TimeSignature.allowedDenominators`); a
    /// slash-number whose denominator isn't one of these is treated as noise, not a meter.
    private static let allowedDenominators: Set<Int> = [2, 4, 8, 16]

    /// Numerators a real time signature can carry (matches `TimeSignature.numeratorRange`).
    private static let numeratorRange = 1...32

    // MARK: - Entry points

    /// Parse recognised OCR lines **with geometry** (the real, on-device path) into a best-effort tempo +
    /// time signature. Geometry lets us rank a tempo mark by page position and recognise a *stacked* time
    /// signature (numerator over denominator, no slash) at the start of the first system.
    static func parse(_ lines: [RecognizedTextLine]) -> SheetMusicImportResult {
        var result = SheetMusicImportResult()
        let strings = lines.map(\.text)

        // Tempo: rank explicit numeric metronome marks by context + position; only fall back to an Italian
        // word when no number is part of a tempo expression anywhere (the spec's "prefer an explicit
        // number").
        if let tempo = detectTempo(lines) {
            result.tempoBPM = tempo.bpm
            result.tempoAlternativeBPM = tempo.alternative
        } else if let match = detectTempoWord(in: strings) {
            result.tempoBPM = match.bpm
            result.tempoWord = match.word
        }

        result.timeSignature = detectTimeSignature(lines)
        return result
    }

    /// String convenience (tests / geometry-less callers): treats each string as a line with no geometry,
    /// so the position-aware rules (stacked geometry, top-region ranking) are skipped but every text rule
    /// (context, slash, symbols, fused digits, tempo words) still applies.
    static func parse(recognizedLines strings: [String]) -> SheetMusicImportResult {
        parse(strings.map { RecognizedTextLine(text: $0) })
    }

    // MARK: - Tempo detection (contextual + spatial ranking)

    /// Rank the numbers that are part of a **tempo expression** and return the best, plus a distinct
    /// runner-up.
    ///
    /// A number is a candidate only when it carries a tempo *cue* — on its own line it sits next to "=", a
    /// beat glyph (♩/J/q/"quarter"), or an Italian tempo word; or, using geometry, a cue box (glyph/"="/word)
    /// sits right beside its box (OCR often splits "♩ = 132" into separate observations). A **bare** number
    /// with no cue — a measure number, a page number, a copyright year, a fingering — is never a tempo.
    ///
    /// Among candidates the score prefers: a stronger cue, a value inside the plausible 30…300 band, and a
    /// position high on the page and toward the left (where tempo marks live). Ties break toward the
    /// earliest number in reading order (so "♩ = 120-132" reads 120, the start of the range).
    private static func detectTempo(_ lines: [RecognizedTextLine]) -> (bpm: Int, alternative: Int?)? {
        // Boxes of lines that themselves carry a tempo cue — used to grant context to a nearby *number* box
        // when OCR split the mark ("♩", "=", "132") into separate observations.
        let cueBoxes: [CGRect] = lines.compactMap { line in
            guard hasEquals(line.text) || hasBeatGlyph(line.text) || tempoWord(in: line.text) != nil,
                  isUsableBox(line.boundingBox) else { return nil }
            return line.boundingBox
        }

        var candidates: [(bpm: Int, score: Double, order: Int, location: Int)] = []
        for (index, line) in lines.enumerated() {
            let tokens = numberTokens(in: line.text)
            guard !tokens.isEmpty else { continue }

            let sameLineEquals = hasEquals(line.text)
            let sameLineGlyph = hasBeatGlyph(line.text)
            let sameLineWord = tempoWord(in: line.text) != nil

            for token in tokens {
                guard acceptableBPM.contains(token.value) else { continue }

                var cue = 0.0
                if sameLineEquals { cue += 100 }
                if sameLineGlyph  { cue += 100 }
                if sameLineWord   { cue += 60 }
                if cue == 0, isUsableBox(line.boundingBox),
                   hasAdjacentCue(numberBox: line.boundingBox, cueBoxes: cueBoxes) {
                    cue += 80
                }
                guard cue > 0 else { continue }   // no tempo context → not a tempo (ignore bare numbers)

                var score = cue
                // Rank a plausible teaching tempo above an accepted-but-extreme one, without excluding the
                // latter when it's all we have (keeps an explicit "♩ = 400" detectable → clamped on apply).
                if !plausibleBPM.contains(token.value) { score -= 1000 }
                if isUsableBox(line.boundingBox) {
                    score += Double(line.boundingBox.midY) * 25       // marks sit high (Vision y↑ = top)
                    score += Double(1 - line.boundingBox.midX) * 8    // …and usually toward the left
                }
                candidates.append((bpm: token.value, score: score, order: index, location: token.location))
            }
        }

        guard !candidates.isEmpty else { return nil }
        let ranked = candidates.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.order != b.order { return a.order < b.order }
            return a.location < b.location
        }
        let best = ranked[0]
        let alternative = ranked.dropFirst().first(where: { $0.bpm != best.bpm })?.bpm
        return (bpm: best.bpm, alternative: alternative)
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

    /// Whether a line carries a beat-unit token — the quarter-note glyph (♩ ♪ ♫ ♬), a standalone "J"/"q"
    /// (how OCR very often mangles ♩), or the word "quarter [note]". The standalone guards keep a "J" or "q"
    /// buried inside an ordinary word ("Justin", "Baroque") from false-matching.
    private static func hasBeatGlyph(_ text: String) -> Bool {
        firstMatch(#"(?:[\x{2669}-\x{266C}]|(?<![A-Za-z])[Jq](?![A-Za-z])|quarter(?:\s*note)?)"#,
                   in: text, options: .caseInsensitive) != nil
    }

    /// Whether a line contains an equals sign — the strongest metronome-mark cue, present even when the beat
    /// glyph was OCR'd away ("= 120", "M.M. = 88").
    private static func hasEquals(_ text: String) -> Bool { text.contains("=") }

    /// The Italian tempo word on a line, if any (so a number sharing the line — "Allegro 132" with the glyph
    /// dropped — can be recognised as that mark's tempo).
    private static func tempoWord(in text: String) -> String? {
        for token in text.components(separatedBy: CharacterSet.letters.inverted) where !token.isEmpty {
            if tempoWordBPM[token.lowercased()] != nil { return token }
        }
        return nil
    }

    /// True when a cue box (glyph/"="/tempo word) sits on roughly the same line as `numberBox` and at or to
    /// its left within arm's reach — i.e. the number is the tail of a split "♩ = 132" mark.
    private static func hasAdjacentCue(numberBox: CGRect, cueBoxes: [CGRect]) -> Bool {
        for cue in cueBoxes where cue != numberBox {
            guard abs(cue.midY - numberBox.midY) <= 0.05 else { continue }   // same row-ish
            let dx = numberBox.midX - cue.midX   // > 0 when the cue is to the left of the number (usual)
            if dx >= -0.05 && dx <= 0.30 { return true }
        }
        return false
    }

    /// The integer number tokens in a line, each with its character offset (for stable, reading-order tie
    /// breaks). Matches runs of 1–4 digits, so a 4-digit year is one out-of-range token ("2026") rather than
    /// a spurious in-range fragment ("202").
    private static func numberTokens(in text: String) -> [(value: Int, location: Int)] {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{1,4}"#) else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            guard let value = Int(ns.substring(with: match.range)) else { return nil }
            return (value: value, location: match.range.location)
        }
    }

    // MARK: - Time-signature detection

    /// Detect a time signature, most-reliable rule first:
    ///   1. an explicit "N/M" slash;
    ///   2. a **stacked** meter — a numerator digit box directly above a denominator digit box (the real,
    ///      no-slash shape on a score), ranked toward the left of the first (top) system;
    ///   3. cut time (¢ / 𝄵 / "cut time");
    ///   4. common time (a lone "C" / 𝄴 / "common time");
    ///   5. a stack OCR'd as a single all-digit token ("44" → 4/4, "68" → 6/8, "916" → 9/16) — last, since
    ///      it is the most guess-y, and (with geometry) only where a meter can sit.
    private static func detectTimeSignature(_ lines: [RecognizedTextLine]) -> TimeSignature? {
        let strings = lines.map(\.text)
        let joined = strings.joined(separator: "\n")

        if let ts = detectSlashMeter(in: strings) { return ts }
        if let ts = detectStackedMeter(lines) { return ts }
        if isCutTime(joined) { return TimeSignature(numerator: 2, denominator: 2) }
        if isCommonTime(lines, joined: joined) { return TimeSignature(numerator: 4, denominator: 4) }
        if let ts = detectFusedDigitMeter(lines) { return ts }
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
    /// `midY`. Among all valid pairs we pick the one most like a *starting* meter: at the **left** of the
    /// **first (top) system**, tightly aligned, small gap. That position preference is what keeps a
    /// stacked-looking pair of fingerings or tuplet numbers further right / lower on the page from winning.
    /// Returns `nil` when no line carries geometry (the string-only path) or nothing lines up.
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
                // Rank toward the start of the first system: left (small midX) and high (small 1−midY),
                // with tight alignment and gap as finer tie-breakers. Lower is better.
                let leftness = top.box.midX
                let topness = 1 - top.box.midY
                let score = dx * 2 + max(gap, 0) * 2 + leftness * 2 + topness
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

    /// Common time: a standalone "C", the common-time glyph, or the words. A *boxed* lone "C" must sit where
    /// a meter sits (left of a system, not a chord symbol or key label elsewhere); a string-only "C" (no
    /// box) is accepted as before.
    private static func isCommonTime(_ lines: [RecognizedTextLine], joined: String) -> Bool {
        let hasLoneC = lines.contains { line in
            guard line.text.trimmingCharacters(in: .whitespacesAndNewlines) == "C" else { return false }
            return !isUsableBox(line.boundingBox)
                || (line.boundingBox.midX <= 0.45 && line.boundingBox.midY >= 0.4)
        }
        return hasLoneC
            || joined.contains("\u{1D134}")    // 𝄴 MUSICAL SYMBOL COMMON TIME
            || firstMatch(#"common[\s-]?time"#, in: joined, options: .caseInsensitive) != nil
    }

    /// A stacked meter that OCR fused into a single all-digit token ("4 4"/"44" → 4/4, "68" → 6/8,
    /// "916" → 9/16, "128" → 12/8). Conservative on purpose to avoid eating opus/measure/page numbers: it
    /// only considers a line that is **entirely** digits (ignoring internal spaces), 2–4 characters, splits
    /// into a valid numerator (1–32) over a musical denominator, and — when the line has geometry — sits
    /// where a meter can (left of a system, not the bottom margin or scattered right). A "16" suffix is
    /// tried first, then a single trailing 2/4/8 — so e.g. "120" (ends in 0) yields nothing.
    private static func detectFusedDigitMeter(_ lines: [RecognizedTextLine]) -> TimeSignature? {
        for line in lines {
            // Positional gate (geometry only): a real meter is at the left of a system, not a page number at
            // the bottom or a measure number off to the right. String-only lines (no box) skip this.
            if isUsableBox(line.boundingBox),
               !(line.boundingBox.midX <= 0.4 && line.boundingBox.midY >= 0.4) { continue }
            let digits = line.text.filter { !$0.isWhitespace }
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

    // MARK: - Geometry helpers

    /// Whether a bounding box carries real geometry (the on-device path) rather than the `.zero` default of
    /// a string-only line.
    private static func isUsableBox(_ box: CGRect) -> Bool {
        !box.isNull && box.width > 0 && box.height > 0
    }

    // MARK: - Regex helpers

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
