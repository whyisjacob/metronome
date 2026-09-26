import SwiftUI
import CoreText

/// Uses the complete engraved SMuFL note glyphs from the bundled Bravura font.
struct SubdivisionNotationView: View {
    let notation: SubdivisionNotation

    var body: some View {
        VStack(spacing: 0) {
            Text(notation.tupletRatio ?? " ")
                .font(.system(size: 10, weight: .medium, design: .serif))
                .frame(height: 11)
            EngravedNote(notation: notation)
                .frame(width: 40, height: 38)
        }
        .accessibilityHidden(true)
    }
}

private struct EngravedNote: Shape {
    let notation: SubdivisionNotation

    func path(in rect: CGRect) -> Path {
        let font = CTFontCreateWithName("Bravura" as CFString, 32, nil)
        var character = notation.smuflNote
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let note = CTFontCreatePathForGlyph(font, glyph, nil) else { return Path() }
        let engraved = CGMutablePath()
        engraved.addPath(note)
        if notation.dotted {
            var dotCharacter: UniChar = 0xE1E7 // SMuFL augmentationDot
            var dotGlyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font, &dotCharacter, &dotGlyph, 1),
               let dot = CTFontCreatePathForGlyph(font, dotGlyph, nil) {
                engraved.addPath(dot, transform: CGAffineTransform(
                    translationX: note.boundingBoxOfPath.maxX + 3, y: 0))
            }
        }
        // Core Text's upward y axis is flipped for SwiftUI. Keep the engraved proportions;
        // reserve two points on each edge so tall 64th/128th flags are never clipped.
        let bounds = engraved.boundingBoxOfPath
        let scale = min(1, min((rect.width - 4) / bounds.width, (rect.height - 4) / bounds.height))
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
            tx: rect.midX - bounds.midX * scale,
            ty: rect.maxY - 2 + bounds.minY * scale)
        guard let fitted = engraved.copy(using: &transform) else { return Path() }
        return Path(fitted)
    }
}
