import XCTest
@testable import Core

final class DeveloperScannerTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DevScannerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func mkdir(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to dir: URL, name: String = "f.bin") throws {
        try Data(repeating: 0xAB, count: bytes).write(to: dir.appendingPathComponent(name))
    }

    func testFindsConfirmedArtifactsAndPrunesNested() async throws {
        // A real project: package.json present → node_modules + .next are confirmed safe.
        let app = try mkdir("myapp")
        try write(1, to: app, name: "package.json")
        let nodeModules = try mkdir("myapp/node_modules")
        try write(4_096, to: nodeModules)
        // A nested node_modules inside the first one — must be pruned, not reported.
        try write(8_192, to: try mkdir("myapp/node_modules/sub/node_modules"))
        try write(2_048, to: try mkdir("myapp/.next"))

        // Rust project with the confirming manifest.
        let rust = try mkdir("rustapp")
        try write(1, to: rust, name: "Cargo.toml")
        try write(4_096, to: try mkdir("rustapp/target"))

        let artifacts = await DeveloperScanner().scan(roots: [root])

        // Exactly one node_modules (nested one pruned).
        let nm = artifacts.filter { $0.kind == "node_modules" }
        XCTAssertEqual(nm.count, 1)
        // Compare paths, not URLs. The scanner's URL comes from
        // FileManager.enumerator, which marks directories as such — so it
        // carries a trailing slash — while `mkdir` above builds a plain
        // appendingPathComponent URL that does not. standardizedFileURL
        // normalizes symlinks and `..` but not directory-ness, so the two
        // compare unequal despite naming the same directory. `.path` drops it,
        // and is what every other comparison in these tests already uses.
        XCTAssertEqual(nm.first?.url.resolvingSymlinksInPath().standardizedFileURL.path,
                       nodeModules.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertTrue(nm.first?.confirmed == true)
        XCTAssertEqual(nm.first?.safety, .safe)
        XCTAssertEqual(nm.first?.projectName, "myapp")
        XCTAssertGreaterThanOrEqual(nm.first?.size ?? 0, 4_096)

        // .next is confirmed safe because package.json sits beside it.
        let next = artifacts.first { $0.kind == ".next" }
        XCTAssertEqual(next?.safety, .safe)

        // target is confirmed via Cargo.toml.
        let target = artifacts.first { $0.kind == "target" }
        XCTAssertEqual(target?.safety, .safe)
        XCTAssertEqual(target?.restoreCommand, "cargo build")
    }

    func testUnconfirmedArtifactIsDowngradedToReview() async throws {
        // .next with no package.json nearby — can't confirm the toolchain.
        try write(2_048, to: try mkdir("orphan/.next"))

        let artifacts = await DeveloperScanner().scan(roots: [root])
        let next = artifacts.first { $0.kind == ".next" }
        XCTAssertNotNil(next)
        XCTAssertEqual(next?.confirmed, false)
        XCTAssertEqual(next?.safety, .reviewRecommended)
    }

    func testVirtualEnvIsReviewTierAndCacheIsSafe() async throws {
        try write(4_096, to: try mkdir("py/__pycache__"))
        try write(4_096, to: try mkdir("py/venv"))

        let artifacts = await DeveloperScanner().scan(roots: [root])
        XCTAssertEqual(artifacts.first { $0.kind == "__pycache__" }?.safety, .safe)
        XCTAssertEqual(artifacts.first { $0.kind == "venv" }?.safety, .reviewRecommended)
    }

    func testNeverDescendsIntoGitInternals() async throws {
        // A node_modules buried inside .git must never be reported.
        try write(4_096, to: try mkdir("repo/.git/node_modules"))

        let artifacts = await DeveloperScanner().scan(roots: [root])
        XCTAssertFalse(artifacts.contains { $0.url.path.contains("/.git/") })
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testResultsSortedBySizeDescending() async throws {
        let app = try mkdir("proj")
        try write(1, to: app, name: "package.json")
        try write(1_024, to: try mkdir("proj/.next"))
        try write(16_384, to: try mkdir("proj/node_modules"))

        let artifacts = await DeveloperScanner().scan(roots: [root])
        XCTAssertEqual(artifacts.map(\.kind).first, "node_modules")
        XCTAssertTrue(artifacts.first!.size >= artifacts.last!.size)
    }
}
