import XCTest
@testable import Core

final class DeletionServiceTests: XCTestCase {

    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeletionServiceTests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func touch(_ name: String, bytes: Int = 1024) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(repeating: 0xCC, count: bytes).write(to: url)
        return url
    }

    func testTrashMovesFilesAndReturnsToken() async throws {
        let a = try touch("a.bin", bytes: 4096)
        let b = try touch("b.bin", bytes: 8192)

        let svc = DeletionService()
        let token = try await svc.trash(urls: [a, b])

        XCTAssertEqual(token.entries.count, 2)
        XCTAssertGreaterThanOrEqual(token.totalBytes, UInt64(4096 + 8192))
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        for entry in token.entries {
            XCTAssertTrue(fm.fileExists(atPath: entry.staged.path))
        }

        // Cleanup so the staging dir doesn't linger across runs.
        try await svc.empty(token)
    }

    func testUndoRestoresOriginals() async throws {
        let a = try touch("restoreme.bin", bytes: 2048)
        let originalPath = a.path

        let svc = DeletionService()
        let token = try await svc.trash(urls: [a])
        XCTAssertFalse(fm.fileExists(atPath: originalPath))

        try await svc.undo(token)
        XCTAssertTrue(fm.fileExists(atPath: originalPath))
        // Staging dir should be cleaned up.
        XCTAssertFalse(fm.fileExists(atPath: token.stagingDir.path))
    }

    func testUndoRefusesWhenOriginalReoccupied() async throws {
        let a = try touch("conflict.bin")
        let svc = DeletionService()
        let token = try await svc.trash(urls: [a])

        // Recreate something at the original path.
        try Data().write(to: a)

        do {
            try await svc.undo(token)
            XCTFail("expected originalReoccupied")
        } catch DeletionError.originalReoccupied(let url) {
            XCTAssertEqual(url.path, a.path)
        } catch {
            XCTFail("unexpected: \(error)")
        }

        // Cleanup.
        try await svc.empty(token)
    }

    func testEmptyRemovesStaging() async throws {
        let a = try touch("ephemeral.bin")
        let svc = DeletionService()
        let token = try await svc.trash(urls: [a])
        XCTAssertTrue(fm.fileExists(atPath: token.stagingDir.path))

        try await svc.empty(token)
        XCTAssertFalse(fm.fileExists(atPath: token.stagingDir.path))
    }

    func testCollidingNamesGetSuffix() async throws {
        let dirA = tmp.appendingPathComponent("subA")
        let dirB = tmp.appendingPathComponent("subB")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        let f1 = dirA.appendingPathComponent("same.txt")
        let f2 = dirB.appendingPathComponent("same.txt")
        try Data().write(to: f1)
        try Data().write(to: f2)

        let svc = DeletionService()
        let token = try await svc.trash(urls: [f1, f2])
        XCTAssertEqual(token.entries.count, 2)
        let names = token.entries.map { $0.staged.lastPathComponent }
        XCTAssertEqual(Set(names).count, 2)  // distinct after suffixing

        try await svc.empty(token)
    }

    // MARK: - Persistence across launches

    /// The headline promise: a clean staged in one session is still restorable
    /// in the next. A fresh `DeletionService` stands in for the relaunched app —
    /// it starts with an empty in-memory token table and must recover the token
    /// from disk.
    func testUndoSurvivesRelaunch() async throws {
        let a = try touch("survives.bin", bytes: 2048)
        let originalPath = a.path

        let firstLaunch = DeletionService()
        let token = try await firstLaunch.trash(urls: [a])
        XCTAssertFalse(fm.fileExists(atPath: originalPath))

        let secondLaunch = DeletionService()
        await secondLaunch.loadPersistedTokens()

        let recovered = await secondLaunch.allTokens()
        XCTAssertTrue(recovered.contains { $0.id == token.id },
                      "token written by the previous launch should be re-hydrated")
        let restorable = await secondLaunch.isRestorable(token.id)
        XCTAssertTrue(restorable)

        try await secondLaunch.undo(id: token.id)
        XCTAssertTrue(fm.fileExists(atPath: originalPath),
                      "undo by id should restore files staged before the 'relaunch'")
    }

    /// If the user empties the Trash in Finder, the on-disk record is dead —
    /// we drop it rather than offering an undo that would fail.
    func testLoadDropsTokensWhoseStagingVanished() async throws {
        let a = try touch("vanishing.bin")
        let firstLaunch = DeletionService()
        let token = try await firstLaunch.trash(urls: [a])

        // Simulate "user emptied the Trash".
        try fm.removeItem(at: token.stagingDir)

        let secondLaunch = DeletionService()
        await secondLaunch.loadPersistedTokens()

        let restorable = await secondLaunch.isRestorable(token.id)
        XCTAssertFalse(restorable)
        let recovered = await secondLaunch.allTokens()
        XCTAssertFalse(recovered.contains { $0.id == token.id })
    }

    // MARK: - Retention sweep

    func testSweepRemovesExpiredStagingAndKeepsFresh() async throws {
        let old = try touch("expired.bin")
        let svc = DeletionService()
        let token = try await svc.trash(urls: [old])
        XCTAssertTrue(fm.fileExists(atPath: token.stagingDir.path))

        // Nothing is due yet under the real 30-day window.
        let sweptEarly = await svc.sweepExpiredTokens()
        XCTAssertEqual(sweptEarly, 0)
        XCTAssertTrue(fm.fileExists(atPath: token.stagingDir.path))

        // A zero-day window makes everything immediately due.
        let swept = await svc.sweepExpiredTokens(olderThanDays: 0)
        XCTAssertEqual(swept, 1)
        XCTAssertFalse(fm.fileExists(atPath: token.stagingDir.path))
        let remaining = await svc.allTokens()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRetentionWindowIsThirtyDays() {
        XCTAssertEqual(DeletionService.retentionDays, 30,
                       "onboarding and Smart Scan both promise a 30-day undo window")
    }
}
