import XCTest
@testable import Metronome

final class SubdivisionNotationTests: XCTestCase {
    func testWrittenDurationMatchesEverySubdivision() {
        for denominator in [2, 4, 8, 16] {
            for numerator in [3, 4, 6, 9, 12] {
                for grouped in [false, true] {
                    let meter = TimeSignature(numerator: numerator, denominator: denominator, groupedBeats: grouped)
                    for subdivision in Subdivision.allCases {
                        let note = subdivision.notation(in: meter)
                        let writtenValue = (note.dotted ? 1.5 : 1.0) / Double(note.denominator)
                        let ratio = Double(note.tupletNormalCount ?? 1) / Double(note.tupletCount ?? 1)
                        let beatValue = Double(meter.groupedBeats ? 3 : 1) / Double(denominator)
                        XCTAssertEqual(writtenValue * ratio,
                            beatValue / Double(subdivision.ticksPerBeat(compound: meter.groupedBeats)), accuracy: 1e-12)
                    }
                }
            }
        }
    }

    func testFamiliarNoteValuesAndFlags() {
        let common = TimeSignature.common
        XCTAssertEqual(Subdivision.quarter.notation(in: common), .init(denominator: 4))
        XCTAssertEqual(Subdivision.eighth.notation(in: common).flagCount, 1)
        XCTAssertEqual(Subdivision.sixteenth.notation(in: common).flagCount, 2)
        XCTAssertEqual(Subdivision.thirtysecond.notation(in: common).flagCount, 3)
        XCTAssertEqual(Subdivision.triplet.notation(in: common),
                       .init(denominator: 8, tupletCount: 3, tupletNormalCount: 2))
        XCTAssertEqual(Subdivision.quarter.notation(in: TimeSignature(numerator: 2, denominator: 2)),
                       .init(denominator: 2))
        XCTAssertEqual(Subdivision.quarter.notation(in: TimeSignature(numerator: 6, denominator: 8)),
                       .init(denominator: 4, dotted: true))
        XCTAssertEqual(Subdivision.quarter.notation(in: TimeSignature(numerator: 6, denominator: 4)),
                       .init(denominator: 2, dotted: true))
    }
}
