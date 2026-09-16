import XCTest
@testable import Core

final class ScanEngineTests: XCTestCase {

    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScanEngineTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    func testScansUserSpaceRuleAndSumsSizes() async throws {
        let dir = tmp.appendingPathComponent("Caches/com.example.app")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4_096).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 0xBB, count: 8_192).write(to: dir.appendingPathComponent("b.bin"))

        let pack = RulePack(
            schemaVersion: 1,
            packVersion: "1.0.0",
            issuedAt: Date(),
            minAppVersion: "1.0.0",
            rules: [
                RulePack.Rule(
                    id: "test.cache",
                    category: .caches,
                    displayName: "Test cache",
                    description: "",
                    safety: .safe,
                    requiresHelper: false,
                    paths: ["\(tmp.path)/Caches/*"],
                    excludes: nil,
                    olderThanDays: nil
                )
            ]
        )

        let results = await ScanEngine().scan(pack: pack)
        XCTAssertEqual(results.count, 1)
        let r = results[0]
        XCTAssertEqual(r.ruleID, "test.cache")
        XCTAssertGreaterThanOrEqual(r.totalSize, 12_288)  // a + b at least
        XCTAssertEqual(r.items.count, 1)                  // one matched root dir
    }

    func testHelperRequiredRuleIsDeferred() async throws {
        let pack = RulePack(
            schemaVersion: 1,
            packVersion: "1.0.0",
            issuedAt: Date(),
            minAppVersion: "1.0.0",
            rules: [
                RulePack.Rule(
                    id: "test.system",
                    category: .caches,
                    displayName: "System cache",
                    description: "",
                    safety: .reviewRecommended,
                    requiresHelper: true,
                    paths: ["/Library/Caches/*"],
                    excludes: nil,
                    olderThanDays: nil
                )
            ]
        )
        let results = await ScanEngine().scan(pack: pack)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].requiresHelper)
        XCTAssertEqual(results[0].totalSize, 0)
        XCTAssertTrue(results[0].items.isEmpty)
    }

    /// Cleaning moves each matched root whole, hidden children included, so the
    /// size we advertise has to include them — otherwise every cache tree with
    /// dot-prefixed internals (npm, Gradle, most browser profiles) reports less
    /// than the clean actually reclaims.
    func testHiddenChildrenCountTowardRuleSize() async throws {
        let dir = tmp.appendingPathComponent("Caches/com.example.hidden")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4_096).write(to: dir.appendingPathComponent("visible.bin"))
        try Data(repeating: 0xBB, count: 16_384).write(to: dir.appendingPathComponent(".hidden.bin"))

        let pack = RulePack(
            schemaVersion: 1,
            packVersion: "1.0.0",
            issuedAt: Date(),
            minAppVersion: "1.0.0",
            rules: [
                RulePack.Rule(
                    id: "test.hidden",
                    category: .caches,
                    displayName: "Hidden cache",
                    description: "",
                    safety: .safe,
                    requiresHelper: false,
                    paths: ["\(tmp.path)/Caches/*"],
                    excludes: nil,
                    olderThanDays: nil
                )
            ]
        )

        let results = await ScanEngine().scan(pack: pack)
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThanOrEqual(
            results[0].totalSize, UInt64(4_096 + 16_384),
            "hidden children must be counted — they are moved by the clean either way")
    }
}
