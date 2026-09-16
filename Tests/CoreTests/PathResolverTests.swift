import XCTest
@testable import Core

final class PathResolverTests: XCTestCase {

    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PathResolverTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func touch(_ relative: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        return url
    }

    private func mkdir(_ relative: String) throws -> URL {
        let url = tmp.appendingPathComponent(relative)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLiteralPath() throws {
        let f = try touch("a.txt")
        let resolver = PathResolver()
        let resolved = resolver.resolve(patterns: [f.path])
        XCTAssertEqual(resolved.map(\.path), [f.path])
    }

    /// `*` matches hidden children too. Cleaning a matched directory removes
    /// its hidden contents regardless, so excluding them from the match only
    /// ever understated what a rule would reclaim.
    func testStarMatchesDirectChildrenIncludingHidden() throws {
        _ = try touch("dir/a.txt")
        _ = try touch("dir/b.txt")
        _ = try touch("dir/.hidden")
        let resolver = PathResolver()
        let resolved = resolver.resolve(patterns: ["\(tmp.path)/dir/*"])
        let names = Set(resolved.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["a.txt", "b.txt", ".hidden"])
    }

    /// The expansion must never escape the directory being globbed.
    func testStarNeverYieldsDotOrDotDot() throws {
        _ = try touch("glob/only.txt")
        let resolver = PathResolver()
        let names = Set(resolver.resolve(patterns: ["\(tmp.path)/glob/*"])
            .map { $0.lastPathComponent })
        XCTAssertFalse(names.contains("."))
        XCTAssertFalse(names.contains(".."))
        XCTAssertEqual(names, ["only.txt"])
    }

    /// `**` descends into hidden directories — `.cache/`-style subtrees are
    /// exactly what the developer and browser rules are aimed at.
    func testDoubleStarDescendsIntoHiddenDirectories() throws {
        _ = try touch("logs/visible/x.log")
        _ = try touch("logs/.hidden/y.log")
        let resolver = PathResolver()
        let names = Set(resolver.resolve(patterns: ["\(tmp.path)/logs/**/*"])
            .map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("y.log"),
                      "a log inside a hidden directory is still a log")
        XCTAssertTrue(names.contains("x.log"))
    }

    /// Widening the match must not weaken excludes — they are applied after
    /// expansion and still win, hidden entries included.
    func testExcludesStillWinOverHiddenMatches() throws {
        _ = try touch("guarded/keep.txt")
        _ = try touch("guarded/.secret")
        let resolver = PathResolver()
        let names = Set(resolver.resolve(
            patterns: ["\(tmp.path)/guarded/*"],
            excludes: ["\(tmp.path)/guarded/.secret"]
        ).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["keep.txt"])
    }

    func testDoubleStarRecursive() throws {
        _ = try touch("d1/x.log")
        _ = try touch("d1/d2/y.log")
        _ = try touch("d1/d2/d3/z.log")
        let resolver = PathResolver()
        let resolved = resolver.resolve(patterns: ["\(tmp.path)/d1/**/*"])
        let names = Set(resolved.map { $0.lastPathComponent })
        XCTAssertTrue(names.isSuperset(of: ["x.log", "y.log", "z.log"]))
    }

    func testExcludesPrefixDropsMatches() throws {
        _ = try mkdir("apps/Keep")
        let drop = try mkdir("apps/Drop")
        _ = try touch("apps/Drop/inner.txt")
        let resolver = PathResolver()
        let resolved = resolver.resolve(
            patterns: ["\(tmp.path)/apps/*"],
            excludes: [drop.path]
        )
        XCTAssertEqual(resolved.map { $0.lastPathComponent }, ["Keep"])
    }

    func testTildeExpansionMatchesHome() {
        // Just verify the helper expands; we don't depend on user-specific files.
        let expanded = PathResolver.expandTilde("~/somewhere")
        XCTAssertEqual(expanded, NSHomeDirectory() + "/somewhere")
    }
}
