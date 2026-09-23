import SwiftUI

/// Vector notation avoids missing musical glyphs in system-font fallbacks.
/// The hollow head, stem, flags and augmentation dot all reflect the actual note value.
struct SubdivisionNotationView: View {
    let notation: SubdivisionNotation

    var body: some View {
        VStack(spacing: 0) {
            Text(notation.tupletRatio ?? " ")
                .font(.system(size: 10, weight: .medium, design: .serif))
                .frame(height: 11)
            ZStack(alignment: .topLeading) {
                if notation.denominator <= 2 {
                    Ellipse().stroke(lineWidth: 1.8)
                        .frame(width: 11, height: 7)
                        .rotationEffect(.degrees(notation.denominator == 1 ? 0 : -20))
                        .position(x: 15, y: 31)
                } else {
                    Ellipse().fill()
                        .frame(width: 11, height: 7)
                        .rotationEffect(.degrees(-20))
                        .position(x: 15, y: 31)
                }
                if notation.denominator > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: 20, y: 30))
                        path.addLine(to: CGPoint(x: 20, y: 4))
                    }.stroke(lineWidth: 1.5)
                }
                ForEach(0..<notation.flagCount, id: \.self) { index in
                    NoteFlag().fill()
                        .frame(width: 12, height: 18)
                        .offset(x: 20, y: 4 + CGFloat(index) * 3.5)
                }
                if notation.dotted {
                    Circle().fill().frame(width: 3, height: 3)
                        .position(x: 29, y: 30)
                }
            }
            .frame(width: 40, height: 38)
        }
        .accessibilityHidden(true)
    }
}

private struct NoteFlag: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addCurve(to: CGPoint(x: 6, y: 18),
                   control1: CGPoint(x: 1, y: 7), control2: CGPoint(x: 17, y: 7))
        p.addCurve(to: CGPoint(x: 1, y: 6),
                   control1: CGPoint(x: 11, y: 10), control2: CGPoint(x: 3, y: 9))
        p.closeSubpath()
        return p
    }
}
