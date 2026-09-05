import Foundation
import CoreGraphics

/// One line of recognized text together with its geometry. `boundingBox` is Vision's normalized rect —
/// origin at the image's **bottom-left**, axes in 0…1 — which lets the parser reason about *layout* (a
/// tempo mark sits high on the page; a vertically **stacked** time signature has its numerator box directly
/// above its denominator box at the start of the first system) without any Vision/UIKit dependency, so the
/// parser stays a pure, testable value type. A geometry-less line (`boundingBox == .zero`, the default)
/// still runs every text-based rule; only the position-aware rules (stacked geometry, top-region tempo
/// ranking, horizontal-band counting-run rejection) need real boxes.
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
    /// when a numeric mark with a strong cue is present; otherwise mapped from an Italian tempo word or
    /// phrase ("Largo assai" → 46).
    var tempoBPM: Int?
    /// The Italian tempo word/phrase the BPM was mapped from, when `tempoBPM` came from a *word* rather
    /// than an explicit number (so the review UI can say "Largo assai → 46"). `nil` when the tempo was an
    /// explicit number, or when no tempo was found.
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
/// Real scores — especially classical/vocal editions — are noisy: a title, composer, measure numbers,
/// fingerings, lyrics, dynamics, penciled counting, a catalog code, a copyright year and page numbers all
/// read as text too, and the tempo is frequently an *Italian word* with no metronome number anywhere. The
/// parser stays out of that "random crap" by being **contextual and spatial** rather than grabbing the
/// first number it sees:
///   * a number only counts as a **tempo** when it carries a *strong* cue — an "=" or a real ♩ beat glyph
///     (a loose OCR "J"/"q" over-fires and is not enough) — AND it survives distractor rejection
///     (penciled counting runs, catalog codes, copyright years, page numbers). If no numeric mark
///     survives, the first **absolute** Italian tempo word wins, adjusted by its modifiers ("assai",
///     "non troppo", …); dynamics and relative/mid-piece terms never set the starting tempo.
///   * a **time signature** is preferentially a vertically *stacked* digit pair at the **left of the first
///     (top) system**; stacked-looking digits elsewhere (fingerings, tuplet numbers, counting) are ranked
///     or filtered out.
///
/// Everything here is best-effort; a miss returns `nil` for that field rather than guessing wildly, and the
/// review UI always shows the raw recognised text plus the chosen values so the user can correct them.
enum SheetMusicOCRParser {

    // MARK: - Tempo vocabulary

    /// Italian **absolute** tempo terms → a representative BPM. These are the fixed anchors; phrase
    /// *modifiers* (assai, poco, non troppo, sostenuto, con moto …) shift the chosen anchor at read time
    /// (see `adjustedTempo`). Used when no numeric metronome mark survives — a strong-cued number wins.
    static let tempoWordBPM: [String: Int] = [
        "grave": 35, "largo": 48, "lento": 52, "larghetto": 60,
        "adagio": 68, "adagietto": 75, "andante": 92, "andantino": 96,
        "moderato": 112, "allegretto": 116, "allegro": 138,
        "vivo": 160, "vivace": 166, "presto": 184, "prestissimo": 204,
    ]

    /// Around this BPM an absolute term flips from "slow" to "fast": it sets the *direction* a modifier
    /// intensifies (assai/molto make a slow term slower and a fast term faster) and the value that
    /// "non troppo" pulls toward.
    private static let moderateBPM = 112

    /// Phrase modifiers we recognise for display, so a chosen phrase reads back as, e.g., "Largo assai"
    /// (dynamics such as "piano" and stray articles such as "e" are dropped). Their BPM effect lives in
    /// `adjustedTempo`.
    private static let modifierWords: Set<String> = [
        "assai", "molto", "poco", "non", "troppo", "ma", "sostenuto", "ritenuto", "con", "moto", "brio",
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
    /// time signature. Geometry lets us rank a tempo mark by page position, recognise a *stacked* time
    /// signature (numerator over denominator, no slash) at the start of the first system, and detect a
    /// penciled counting run strung across a horizontal band.
    static func parse(_ lines: [RecognizedTextLine]) -> SheetMusicImportResult {
        var result = SheetMusicImportResult()
        let strings = lines.map(\.text)

        // Numbers that are page annotation, not music — counting runs, catalog codes, copyright years —
        // are excluded from BOTH tempo and time-signature candidacy.
        let excluded = distractorTokens(lines)

        // Tempo: a NUMBER wins only with a strong cue (= or a real ♩ glyph) and only if it survives the
        // distractor rejection above; otherwise fall back to the first ABSOLUTE Italian tempo word/phrase.
        if let tempo = detectTempo(lines, excluded: excluded) {
            result.tempoBPM = tempo.bpm
            result.tempoAlternativeBPM = tempo.alternative
        } else if let match = detectTempoWord(in: strings) {
            result.tempoBPM = match.bpm
            result.tempoWord = match.word
        }

        result.timeSignature = detectTimeSignature(lines, excluded: excluded)
        return result
    }

    /// String convenience (tests / geometry-less callers): treats each string as a line with no geometry,
    /// so the position-aware rules (stacked geometry, top-region ranking, band counting-run) are skipped but
    /// every text rule (context, slash, symbols, fused digits, tempo words, within-line counting) applies.
    static func parse(recognizedLines strings: [String]) -> SheetMusicImportResult {
        parse(strings.map { RecognizedTextLine(text: $0) })
    }

    // MARK: - Tempo detection (contextual + spatial ranking)

    /// Rank the numbers that are part of a **tempo expression** and return the best, plus a distinct
    /// runner-up.
    ///
    /// A number is a candidate only when it carries a *strong* tempo cue — on its own line it sits next to
    /// "=" or a real beat glyph (♩ ♪ ♫ ♬ / "quarter [note]"); or, using geometry, such a cue box sits right
    /// beside its box (OCR often splits "♩ = 132" into separate observations). A loose standalone "J"/"q"
    /// (a frequent OCR mangle of ♩) is deliberately **not** a strong cue — on its own it over-fires. A
    /// **bare** number with no cue — a measure number, a page number, a copyright year, a fingering — is
    /// never a tempo, and a number the distractor pass flagged (a counting integer, a catalog code, a year)
    /// is dropped even beside a cue.
    ///
    /// Among candidates the score prefers: a stronger cue, a value inside the plausible 30…300 band, and a
    /// position high on the page and toward the left (where tempo marks live). Ties break toward the
    /// earliest number in reading order (so "♩ = 120-132" reads 120, the start of the range).
    private static func detectTempo(_ lines: [RecognizedTextLine],
                                    excluded: Set<NumberToken>) -> (bpm: Int, alternative: Int?)? {
        // Boxes of lines that themselves carry a STRONG cue — used to grant context to a nearby *number*
        // box when OCR split the mark ("♩", "=", "132") into separate observations.
        let cueBoxes: [CGRect] = lines.compactMap { line in
            guard hasEquals(line.text) || hasStrongBeatCue(line.text),
                  isUsableBox(line.boundingBox) else { return nil }
            return line.boundingBox
        }

        var candidates: [(bpm: Int, score: Double, order: Int, location: Int)] = []
        for (index, line) in lines.enumerated() {
            let tokens = numberTokens(in: line.text)
            guard !tokens.isEmpty else { continue }

            let sameLineEquals = hasEquals(line.text)
            let sameLineGlyph = hasStrongBeatCue(line.text)

            for token in tokens {
                guard acceptableBPM.contains(token.value) else { continue }
                // Survive distractor rejection: a counting integer, catalog code or copyright year is
                // never a tempo, even if a cue happens to sit beside it.
                guard !excluded.contains(NumberToken(line: index, value: token.value)) else { continue }

                var cue = 0.0
                if sameLineEquals { cue += 100 }
                if sameLineGlyph  { cue += 100 }
                if cue == 0, isUsableBox(line.boundingBox),
                   hasAdjacentCue(numberBox: line.boundingBox, cueBoxes: cueBoxes) {
                    cue += 80
                }
                guard cue > 0 else { continue }   // no STRONG tempo cue → not a tempo (ignore bare numbers)

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

    /// The first **absolute** Italian tempo word in reading order, with its representative BPM adjusted by
    /// any modifiers on that line. Scans each line's letter-tokens; a line whose first tempo token is a
    /// *dynamic* (piano, forte, mezzo …) or a *relative/mid-piece* term (rit., rall., accel., a tempo,
    /// più/meno mosso, colla voce …) yields nothing there, because none of those are absolute terms — so
    /// they never set the starting tempo. Trailing punctuation and surrounding words don't hide the match.
    private static func detectTempoWord(in lines: [String]) -> (word: String, bpm: Int)? {
        for line in lines {
            let tokens = line.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            guard let termIndex = tokens.firstIndex(where: { tempoWordBPM[$0.lowercased()] != nil }) else {
                continue
            }
            let term = tokens[termIndex]
            let base = tempoWordBPM[term.lowercased()]!
            let bpm = adjustedTempo(base: base, phrase: line)
            let word = displayTempoPhrase(term: term, after: Array(tokens[(termIndex + 1)...]))
            return (word: word, bpm: bpm)
        }
        return nil
    }

    /// Apply Italian phrase modifiers to an absolute term's representative BPM. Direction is set by whether
    /// the term is slow or fast (relative to `moderateBPM`):
    ///   * **assai / molto** ("very") — intensify in the term's own direction (Largo assai → slower ~46;
    ///     Allegro molto → faster).
    ///   * **poco** ("a little") — a mild nudge in the term's direction.
    ///   * **non troppo** ("not too much") — pull toward a moderate tempo (Allegro non troppo → ~132).
    ///   * **sostenuto / ritenuto** ("held back") — slower.
    ///   * **con moto / con brio** ("with motion / spirit") — toward the faster end.
    /// Dynamics (piano, forte, …) carry no tempo meaning and are simply not modifiers, so a phrase like
    /// "Largo assai e piano" applies only "assai".
    private static func adjustedTempo(base: Int, phrase: String) -> Int {
        var bpm = Double(base)
        let slow = base < moderateBPM
        let p = " " + phrase.lowercased() + " "
        if p.contains(" non troppo") { bpm += 0.25 * (Double(moderateBPM) - bpm) }
        if p.contains(" assai") || p.contains(" molto") { bpm *= slow ? 0.95 : 1.06 }
        if p.contains(" poco") { bpm *= slow ? 0.985 : 1.03 }
        if p.contains(" sostenuto") || p.contains(" ritenuto") { bpm *= 0.94 }
        if p.contains(" con moto") || p.contains(" con brio") { bpm *= 1.06 }
        return Int(bpm.rounded())
    }

    /// Build the human-readable phrase for the review UI: the absolute term (capitalised) followed by any
    /// recognised modifier words, in order, until a second absolute term begins a new mark. Dynamics and
    /// stray words are dropped, so "Largo assai e piano" reads back as "Largo assai".
    private static func displayTempoPhrase(term: String, after rest: [String]) -> String {
        var parts = [term.lowercased().capitalized]
        for token in rest {
            let lower = token.lowercased()
            if tempoWordBPM[lower] != nil { break }          // a second absolute term ends this mark
            if modifierWords.contains(lower) { parts.append(lower) }
        }
        return parts.joined(separator: " ")
    }

    /// Whether a line carries a **strong** beat-unit cue for a metronome mark: a real note glyph
    /// (♩ ♪ ♫ ♬) or the spelled-out word "quarter [note]". A loose standalone "J"/"q" (a frequent OCR
    /// mangle of ♩) is deliberately **excluded** — on its own it over-fires on ordinary text, so a number
    /// needs an "=" or a real glyph/word to count as a tempo.
    private static func hasStrongBeatCue(_ text: String) -> Bool {
        firstMatch(#"(?:[\x{2669}-\x{266C}]|quarter(?:\s*note)?)"#, in: text, options: .caseInsensitive) != nil
    }

    /// Whether a line contains an equals sign — the strongest metronome-mark cue, present even when the beat
    /// glyph was OCR'd away ("= 120", "M.M. = 88").
    private static func hasEquals(_ text: String) -> Bool { text.contains("=") }

    /// True when a cue box (glyph/"=") sits on roughly the same line as `numberBox` and at or to its left
    /// within arm's reach — i.e. the number is the tail of a split "♩ = 132" mark.
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

    // MARK: - Distractor rejection (counting runs, catalog codes, copyright years)

    /// A number's identity in the observation set: which recognised line it sits on and its value. That is
    /// enough to tag a specific number as page annotation and then exclude it from BOTH tempo and
    /// time-signature candidacy — no character offset is needed because our distractor classes never keep
    /// one occurrence of a repeated value while dropping another on the same line.
    private struct NumberToken: Hashable {
        let line: Int
        let value: Int
    }

    /// Classify the numbers on the page that are **not** music, so both detectors can ignore them:
    ///   * a monotonic run of **≥3 consecutive integers** — penciled beat/finger counting ("1 2 3 4 5 …") —
    ///     whether OCR returned it as one line or as separate boxes strung left-to-right across a band;
    ///   * a **copyright year** (a 4-digit 1800…2099 — a Roman-numeral year like "MCMLXIII" carries no
    ///     digits, so it is already inert and never a candidate);
    ///   * a **catalog / opus code** — digits led by a letter ("R 8039").
    /// Page numbers stay handled by the existing positional gates (a lone small int in a margin/corner).
    private static func distractorTokens(_ lines: [RecognizedTextLine]) -> Set<NumberToken> {
        var excluded = Set<NumberToken>()
        var located: [(token: NumberToken, box: CGRect)] = []

        for (index, line) in lines.enumerated() {
            let tokens = numberTokens(in: line.text)
            for token in tokens {
                let id = NumberToken(line: index, value: token.value)
                located.append((token: id, box: line.boundingBox))
                if (1800...2099).contains(token.value) { excluded.insert(id) }        // copyright year
            }
            for value in catalogNumbers(in: line.text) {                              // catalog / opus code
                excluded.insert(NumberToken(line: index, value: value))
            }
            // A counting run OCR'd as a single line ("1 2 3 4 5 6 7"), tokens already in reading order.
            markConsecutiveRun(tokens.map { NumberToken(line: index, value: $0.value) }, into: &excluded)
        }
        // A counting run OCR'd as separate boxes strung left-to-right across a horizontal band.
        markBandRun(located, into: &excluded)
        return excluded
    }

    /// Mark every number in a maximal ascending-by-one run of length ≥3, given the tokens already in
    /// reading order. A real 2-number meter ("3 4") never reaches the threshold.
    private static func markConsecutiveRun(_ ordered: [NumberToken], into excluded: inout Set<NumberToken>) {
        guard ordered.count >= 3 else { return }
        for start in 0..<ordered.count {
            var run = [ordered[start]]
            var next = start + 1
            while next < ordered.count, ordered[next].value == run[run.count - 1].value + 1 {
                run.append(ordered[next]); next += 1
            }
            if run.count >= 3 { for token in run { excluded.insert(token) } }
        }
    }

    /// Mark counting runs OCR returned as separate boxes: cluster the geometry-bearing numbers into
    /// horizontal bands (similar `midY`), then within a band grow runs of ascending-by-one values that step
    /// rightwards (increasing `midX`). Requiring a real horizontal step is what keeps a *vertically stacked*
    /// pair — a "3" over a "4" (a real ¾ meter), same `midX` — from ever reading as a counting run; and a
    /// 2-digit meter is only two numbers anyway, below the ≥3 threshold.
    private static func markBandRun(_ located: [(token: NumberToken, box: CGRect)],
                                    into excluded: inout Set<NumberToken>) {
        var remaining = located.filter { isUsableBox($0.box) }.sorted { $0.box.midY > $1.box.midY }
        guard remaining.count >= 3 else { return }
        let bandTolY: CGFloat = 0.03
        let minStepX: CGFloat = 0.005
        while !remaining.isEmpty {
            let anchorY = remaining[0].box.midY
            let band = remaining.filter { abs($0.box.midY - anchorY) <= bandTolY }
            remaining.removeAll { abs($0.box.midY - anchorY) <= bandTolY }
            guard band.count >= 3 else { continue }
            let sorted = band.sorted { $0.box.midX < $1.box.midX }
            for start in 0..<sorted.count {
                var run = [sorted[start]]
                var next = start + 1
                while next < sorted.count {
                    let prev = run[run.count - 1], cur = sorted[next]
                    if cur.token.value == prev.token.value + 1, cur.box.midX > prev.box.midX + minStepX {
                        run.append(cur); next += 1
                    } else { break }
                }
                if run.count >= 3 { for member in run { excluded.insert(member.token) } }
            }
        }
    }

    /// The numeric values on a line that read as catalog / opus codes — digits led by a letter (optionally a
    /// single period and up to two spaces), e.g. "R 8039" or "No. 14". Crucially the gap allows only a
    /// period/spaces, never an "=" or a beat glyph, so a real mark ("quarter = 96", "J = 120", "♩ 96") is
    /// not caught.
    private static func catalogNumbers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z]\.?\s{0,2}([0-9]{1,4})"#) else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return nil }
            return Int(ns.substring(with: range))
        }
    }

    /// Whether **every** number on a line is a distractor — so a whole-line meter reading (stacked or fused)
    /// for that line should be skipped. A line with no numbers is not excluded.
    private static func lineNumbersAllExcluded(_ lineIndex: Int, text: String,
                                               excluded: Set<NumberToken>) -> Bool {
        let tokens = numberTokens(in: text)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { excluded.contains(NumberToken(line: lineIndex, value: $0.value)) }
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
    /// A denominator-8 meter whose numerator is a multiple of three (6/9/12) is *compound*; the parser just
    /// emits the right `TimeSignature` and the engine handles the dotted-quarter beat.
    private static func detectTimeSignature(_ lines: [RecognizedTextLine],
                                            excluded: Set<NumberToken>) -> TimeSignature? {
        let strings = lines.map(\.text)
        let joined = strings.joined(separator: "\n")

        if let ts = detectSlashMeter(in: strings) { return ts }
        if let ts = detectStackedMeter(lines, excluded: excluded) { return ts }
        if isCutTime(joined) { return TimeSignature(numerator: 2, denominator: 2) }
        if isCommonTime(lines, joined: joined) { return TimeSignature(numerator: 4, denominator: 4) }
        if let ts = detectFusedDigitMeter(lines, excluded: excluded) { return ts }
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
    /// A line whose number the distractor pass flagged (a counting integer, a year) is skipped outright.
    /// Returns `nil` when no line carries geometry (the string-only path) or nothing lines up.
    private static func detectStackedMeter(_ lines: [RecognizedTextLine],
                                           excluded: Set<NumberToken>) -> TimeSignature? {
        let numerics: [(value: Int, box: CGRect)] = lines.enumerated().compactMap { entry in
            let (index, line) = entry
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = line.boundingBox
            guard !box.isNull, box.width > 0, box.height > 0, let value = Int(text) else { return nil }
            guard !lineNumbersAllExcluded(index, text: line.text, excluded: excluded) else { return nil }
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
    /// only considers a line that is **entirely** digits (ignoring internal spaces), 2–4 characters, is not
    /// a flagged distractor (a copyright year like "2016" would otherwise split into "20/16"), splits into a
    /// valid numerator (1–32) over a musical denominator, and — when the line has geometry — sits where a
    /// meter can (left of a system, not the bottom margin or scattered right). A "16" suffix is tried first,
    /// then a single trailing 2/4/8 — so e.g. "120" (ends in 0) yields nothing.
    private static func detectFusedDigitMeter(_ lines: [RecognizedTextLine],
                                              excluded: Set<NumberToken>) -> TimeSignature? {
        for (index, line) in lines.enumerated() {
            if lineNumbersAllExcluded(index, text: line.text, excluded: excluded) { continue }
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
