import XCTest
@testable import Core

final class DiskSpaceReaderTests: XCTestCase {

    // MARK: - Arithmetic

    func testUsedBytesAndFraction() {
        let d = DiskSpace(totalBytes: 1_000, availableBytes: 250)
        XCTAssertEqual(d.usedBytes, 750)
        XCTAssertEqual(d.usedFraction, 0.75, accuracy: 0.0001)
    }

    /// `volumeAvailableCapacityForImportantUsage` counts purgeable space, so it
    /// can legitimately exceed total. That must not underflow UInt64.
    func testAvailableExceedingTotalDoesNotUnderflow() {
        let d = DiskSpace(totalBytes: 500, availableBytes: 900)
        XCTAssertEqual(d.usedBytes, 0)
        XCTAssertEqual(d.usedFraction, 0)
    }

    func testUnknownCapacityReportsZeroRatherThanDividingByZero() {
        let d = DiskSpace(totalBytes: 0, availableBytes: 0)
        XCTAssertEqual(d.usedFraction, 0)
        XCTAssertEqual(d.usedBytes, 0)
    }

    func testFractionIsClampedToOne() {
        // Defensive: a bogus reading must not drive a progress bar past full.
        let d = DiskSpace(totalBytes: 100, availableBytes: 0)
        XCTAssertEqual(d.usedFraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - Live read

    func testRootVolumeReadsPlausibleValues() throws {
        let snap = try XCTUnwrap(DiskSpaceReader.snapshot(),
                                 "the boot volume should always be readable")
        XCTAssertGreaterThan(snap.totalBytes, 0)
        XCTAssertLessThanOrEqual(snap.usedFraction, 1.0)
        XCTAssertGreaterThanOrEqual(snap.usedFraction, 0.0)
    }

    func testNonexistentPathReturnsNil() {
        let missing = URL(fileURLWithPath: "/definitely/not/a/volume/\(UUID().uuidString)")
        XCTAssertNil(DiskSpaceReader.snapshot(for: missing))
    }
}
