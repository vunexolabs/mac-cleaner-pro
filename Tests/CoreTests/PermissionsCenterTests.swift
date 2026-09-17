import XCTest
@testable import Core

final class PermissionsCenterTests: XCTestCase {

    /// Every permission has to carry copy the UI can show verbatim. A blank
    /// rationale would surface as an empty row rather than an obvious bug.
    func testEveryPermissionExplainsItself() {
        for permission in Permission.allCases {
            XCTAssertFalse(permission.title.isEmpty, "\(permission) has no title")
            XCTAssertFalse(permission.rationale.isEmpty, "\(permission) has no rationale")
            XCTAssertFalse(permission.costOfDenial.isEmpty, "\(permission) has no stated cost")
            XCTAssertFalse(permission.gatedFeatures.isEmpty, "\(permission) gates nothing")
        }
    }

    /// Full Disk Access is applied at process start. Forgetting this is why
    /// "I granted it and nothing changed" is the most common support report.
    func testFullDiskAccessIsMarkedAsNeedingRelaunch() {
        XCTAssertTrue(Permission.fullDiskAccess.needsRelaunchAfterGranting)
        XCTAssertTrue(Permission.fullDiskAccess.requiresSystemSettings)
    }

    /// Automation is prompted by macOS on first use; we cannot know in advance
    /// and must not claim to.
    func testAutomationStatusIsNotGuessed() {
        XCTAssertEqual(PermissionsCenter.status(of: .automation), .decidedOnFirstUse)
        XCTAssertFalse(Permission.automation.requiresSystemSettings)
    }

    /// `outstanding()` drives the UI's to-do list, so it may only contain
    /// things the user can actually act on.
    func testOutstandingOnlyContainsActionableDenials() {
        for permission in PermissionsCenter.outstanding() {
            XCTAssertEqual(PermissionsCenter.status(of: permission), .denied)
        }
    }

    func testAllClearAgreesWithOutstanding() {
        XCTAssertEqual(PermissionsCenter.allClear, PermissionsCenter.outstanding().isEmpty)
    }
}
