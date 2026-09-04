import XCTest
@testable import Metronome

/// The information-architecture guard: every user-facing control has exactly one home, the main screen
/// holds only the base controls, and every Settings section is actually used. This is the automated
/// check that "no non-base control is orphaned" — if a control is added without a placement, or a section
/// is left with no control, one of these fails.
final class SettingsCatalogTests: XCTestCase {

    /// The main screen is the absolute base only — tempo, transport, meter, subdivision, beat visual.
    func testMainScreenHoldsOnlyTheBaseControls() {
        let onMain = AppControl.allCases.filter { $0.placement == .mainScreen }
        XCTAssertEqual(Set(onMain), [.tempo, .transport, .timeSignature, .subdivision, .beatVisual])
    }

    /// Nothing is stranded: every control that isn't a base control lives in some Settings section.
    func testEveryNonBaseControlLivesInASettingsSection() {
        for control in AppControl.allCases where control.placement != .mainScreen {
            if case .settings = control.placement { continue }
            XCTFail("\(control) is neither a base control nor in a Settings section — it is orphaned")
        }
    }

    /// No empty sections: every declared Settings section is referenced by at least one control (and no
    /// control points at a section that isn't in the list).
    func testEverySettingsSectionIsUsedByExactlyTheControls() {
        let used = Set(AppControl.allCases.compactMap { control -> SettingsSection? in
            if case let .settings(section) = control.placement { return section }
            return nil
        })
        XCTAssertEqual(used, Set(SettingsSection.allCases),
                       "a Settings section has no control, or a control references a missing section")
    }

    func testSettingsSectionsAreTheExpectedEightInOrder() {
        XCTAssertEqual(SettingsSection.allCases.map(\.rawValue),
                       ["sound", "voice", "groove", "accents", "visuals", "borderFlash", "gapTrainer", "recents"])
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.systemImage.isEmpty, "\(section) has no icon")
        }
    }

    /// Placement is total and single-valued: every control is exactly one of base / settings, and the two
    /// partitions add up to the whole roster (belt-and-suspenders against a future third placement).
    func testPlacementPartitionsEveryControl() {
        let base = AppControl.allCases.filter { $0.placement == .mainScreen }.count
        let inSettings = AppControl.allCases.filter {
            if case .settings = $0.placement { return true }
            return false
        }.count
        XCTAssertEqual(base + inSettings, AppControl.allCases.count)
        XCTAssertGreaterThan(base, 0)
        XCTAssertGreaterThan(inSettings, 0)
    }
}
