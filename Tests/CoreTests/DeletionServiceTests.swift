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

    // MARK: - Undo is all-or-nothing

    /// A conflict on any entry must leave *every* entry where it was. The old
    /// loop validated as it went, so entries before the conflict were already
    /// moved back — a half-restored tree, reported as a plain error.
    func testUndoConflictRestoresNothing() async throws {
        let first  = try touch("first.bin")
        let second = try touch("second.bin")
        let firstPath = first.path

        let svc = DeletionService()
        let token = try await svc.trash(urls: [first, second])
        XCTAssertEqual(token.entries.count, 2)

        // Re-occupy the *second* original; the first is still clear.
        try Data().write(to: second)

        do {
            try await svc.undo(token)
            XCTFail("expected originalReoccupied")
        } catch DeletionError.originalReoccupied {
            // Expected.
        }

        XCTAssertFalse(fm.fileExists(atPath: firstPath),
                       "no entry may be restored when another entry conflicts")
        let stillStaged = await svc.isRestorable(token.id)
        XCTAssertTrue(stillStaged, "the token survives so the user can retry")

        // Clearing the conflict lets the whole set restore.
        try fm.removeItem(at: second)
        try await svc.undo(token)
        XCTAssertTrue(fm.fileExists(atPath: firstPath))
        XCTAssertTrue(fm.fileExists(atPath: second.path))
    }

    // MARK: - Byte accounting

    /// `trash` moves directories whole, so the reported size must include the
    /// hidden children that went with them.
    func testStagedSizeIncludesHiddenChildren() async throws {
        let dir = tmp.appendingPathComponent("cachedir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: 4_096).write(to: dir.appendingPathComponent("visible.bin"))
        try Data(repeating: 0xBB, count: 16_384).write(to: dir.appendingPathComponent(".hidden.bin"))

        let svc = DeletionService()
        let token = try await svc.trash(urls: [dir])
        XCTAssertGreaterThanOrEqual(token.totalBytes, UInt64(4_096 + 16_384),
                                    "hidden children moved with the directory must be counted")

        try await svc.empty(token)
    }

    // MARK: - Deletion mode

    func testDefaultModeIsTrashFirst() async {
        let svc = DeletionService()
        let mode = await svc.currentMode()
        XCTAssertEqual(mode, .trash, "trash-first is the safe default and the basis for undo")
        XCTAssertTrue(DeletionMode.trash.isReversible)
        XCTAssertFalse(DeletionMode.permanent.isReversible)
    }

    func testPermanentModeDeletesOutrightAndStagesNothing() async throws {
        let a = try touch("gone.bin", bytes: 4096)
        let path = a.path

        let svc = DeletionService()
        await svc.setMode(.permanent)
        let result = try await svc.trashWithFailures(urls: [a])

        XCTAssertFalse(fm.fileExists(atPath: path), "the file should be gone, not staged")
        XCTAssertTrue(result.token.entries.isEmpty, "nothing is staged, so there is nothing to restore")
        XCTAssertGreaterThanOrEqual(result.token.totalBytes, 4096)

        // And it must not advertise an undo it cannot honour.
        let restorable = await svc.isRestorable(result.token.id)
        XCTAssertFalse(restorable)
    }

    func testSwitchingBackToTrashStagesAgain() async throws {
        let a = try touch("staged.bin")
        let svc = DeletionService()
        await svc.setMode(.permanent)
        await svc.setMode(.trash)

        let token = try await svc.trash(urls: [a])
        XCTAssertEqual(token.entries.count, 1)
        let restorable = await svc.isRestorable(token.id)
        XCTAssertTrue(restorable)

        try await svc.empty(token)
    }

    func testRetentionWindowIsThirtyDays() {
        XCTAssertEqual(DeletionService.retentionDays, 30,
                       "onboarding and Smart Scan both promise a 30-day undo window")
    }
}
