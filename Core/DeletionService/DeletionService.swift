import Foundation

/// One staged entry inside an `UndoToken` — original location plus where the file
/// now sits in the staging trash directory.
public struct StagedEntry: Codable, Sendable, Hashable {
    public let original: URL
    public let staged: URL
    public let bytes: UInt64
}

/// One per-item failure — surfaced to the UI so the user knows why some
/// selections didn't move (commonly TCC-protected paths like HomeKit, Photos).
public struct DeletionFailure: Sendable, Hashable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}

/// Receipt for a `trash` operation. Hand it back to `undo` to restore, or to
/// `empty` to permanently delete. Tokens are also persisted to disk so undo
/// survives an app relaunch within the retention window — call
/// ``DeletionService/loadPersistedTokens()`` once at launch to re-hydrate them.
public struct UndoToken: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let stagingDir: URL
    public let entries: [StagedEntry]
    public let totalBytes: UInt64

    public init(id: UUID, createdAt: Date, stagingDir: URL,
                entries: [StagedEntry], totalBytes: UInt64) {
        self.id = id; self.createdAt = createdAt; self.stagingDir = stagingDir
        self.entries = entries; self.totalBytes = totalBytes
    }
}

/// Result of a trash operation. May contain partial successes alongside
/// per-item failures — TCC sandbox denials are normal and shouldn't abort
/// the whole batch.
public struct TrashResult: Sendable {
    public let token: UndoToken
    public let failures: [DeletionFailure]
    public init(token: UndoToken, failures: [DeletionFailure]) {
        self.token = token; self.failures = failures
    }
}

public enum DeletionError: Error, Sendable {
    case sourceMissing(URL)
    case unknownToken(UUID)
    case originalReoccupied(URL)
    case ioFailure(underlying: String)
}

/// Trash-first deletion with undo.
///
/// Files are moved (rename, not copy) into `~/.Trash/MacCleanerPro/<UUID>/`,
/// preserving their basename. Collisions get a numeric suffix. Each operation
/// returns an `UndoToken` that can:
///   - `undo`  → move every entry back to its original URL
///   - `empty` → permanently delete the staging directory and forget the token
///
/// Tokens are also serialized to a sibling `tokens/<id>.json` so the UI can
/// surface "Recently cleaned" across launches. Files staged in `~/.Trash/` are
/// also visible in Finder's Trash, where the user can empty them manually — at
/// which point our undo will fail cleanly with `sourceMissing`.
/// How the user wants cleaned files disposed of.
public enum DeletionMode: String, Sendable, CaseIterable {
    /// Move to `~/.Trash/MacCleanerPro/<UUID>/`, recoverable until the Trash is
    /// emptied or the retention window elapses. The default, and the reason
    /// this app can offer undo at all.
    case trash
    /// Delete outright. No undo, no Activity Log restore, nothing to put back.
    case permanent

    public var isReversible: Bool { self == .trash }
}

public actor DeletionService {

    public static let shared = DeletionService()

    /// Disposal mode for subsequent cleans. `.trash` unless the user has
    /// explicitly chosen otherwise in Settings.
    ///
    /// Deliberately not persisted here — Core has no business reading
    /// UserDefaults — the app sets it at launch and whenever the setting
    /// changes.
    private var mode: DeletionMode = .trash

    public func setMode(_ newMode: DeletionMode) { mode = newMode }
    public func currentMode() -> DeletionMode { mode }

    private let fm = FileManager.default
    private var tokens: [UUID: UndoToken] = [:]

    public init() {}

    // MARK: - Public API

    /// Move `urls` into a fresh staging directory and return a result containing
    /// the undo token plus any per-item failures.
    ///
    /// Per-item resilience: a single TCC-protected path (e.g. `com.apple.HomeKit`,
    /// `com.apple.Photos`) is denied even with Full Disk Access. Aborting the
    /// whole batch on the first denial would leave 99% of reclaimable data on
    /// the user's disk and surface a confusing error. Instead we collect the
    /// failure, continue, and let the UI surface "moved X, skipped Y".
    public func trashWithFailures(urls: [URL],
                                  source: ActivityEntry.Source = .manual) async throws -> TrashResult {
        let id = UUID()
        var entries: [StagedEntry] = []
        var failures: [DeletionFailure] = []
        var total: UInt64 = 0

        guard mode == .trash else {
            return try permanentlyDelete(urls: urls, id: id, source: source)
        }

        let staging = try newStagingDir(id: id)
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let dest = uniqueDestination(in: staging, for: url)
            do {
                try fm.moveItem(at: url, to: dest)
                let bytes = (try? Self.allocatedSize(of: dest)) ?? 0
                entries.append(StagedEntry(original: url, staged: dest, bytes: bytes))
                total &+= bytes
            } catch {
                failures.append(DeletionFailure(
                    url: url,
                    reason: Self.shortReason(from: error)))
            }
        }

        let token = UndoToken(id: id, createdAt: Date(),
                              stagingDir: staging, entries: entries, totalBytes: total)
        tokens[id] = token
        try persist(token)
        await ActivityLog.shared.append(ActivityEntry(
            kind: .clean, source: source, bytes: total,
            itemCount: entries.count, tokenID: id))
        return TrashResult(token: token, failures: failures)
    }

    /// Delete outright, for users who have turned off trash-first in Settings.
    ///
    /// Returns a token with no entries: there is nothing staged, so undo has
    /// nothing to restore. The Activity Log records the action with a note
    /// saying so, because "cleaned 4 GB" with a dead Undo button would be worse
    /// than saying plainly that it is gone.
    private func permanentlyDelete(urls: [URL],
                                   id: UUID,
                                   source: ActivityEntry.Source) throws -> TrashResult {
        var failures: [DeletionFailure] = []
        var total: UInt64 = 0
        var count = 0

        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            let bytes = (try? Self.allocatedSize(of: url)) ?? 0
            do {
                try fm.removeItem(at: url)
                total &+= bytes
                count += 1
            } catch {
                failures.append(DeletionFailure(url: url,
                                                reason: Self.shortReason(from: error)))
            }
        }

        let token = UndoToken(id: id, createdAt: Date(),
                              stagingDir: Self.rootStagingDir(),
                              entries: [], totalBytes: total)
        // Not persisted: there is nothing to restore, so a record would only
        // produce an undo affordance that cannot work.
        Task { [total, count, id] in
            await ActivityLog.shared.append(ActivityEntry(
                kind: .empty, source: source, bytes: total,
                itemCount: count, tokenID: id,
                note: "Deleted permanently — trash-first is off"))
        }
        return TrashResult(token: token, failures: failures)
    }

    /// Back-compat shim. Returns just the token; partial failures are silently
    /// dropped. Call sites that want failure visibility should use
    /// `trashWithFailures` instead.
    @discardableResult
    public func trash(urls: [URL], source: ActivityEntry.Source = .manual) async throws -> UndoToken {
        try await trashWithFailures(urls: urls, source: source).token
    }

    /// Distill an `Error` (often a deeply-nested `NSError` with `underlying`
    /// chains and TCC-specific prefixes) into a one-line user-facing reason.
    private static func shortReason(from error: Error) -> String {
        let ns = error as NSError
        // TCC denial path: code 257 (NSFileReadNoPermissionError) or message
        // containing "you don't have permission" — surface a short hint.
        let msg = ns.localizedDescription
        if msg.contains("you don't have permission") || msg.contains("Operation not permitted") {
            return "Permission denied (TCC-protected)"
        }
        return msg
    }

    /// Restore every entry in `token` to its original URL. Never overwrites live
    /// state, and never leaves a half-restored tree behind.
    ///
    /// Validation runs over **every** entry before the first file moves. The
    /// previous version validated inside the move loop, so an entry whose
    /// original had been re-occupied aborted the restore with earlier entries
    /// already moved back and no record of which ones — the user was left
    /// halfway, with the same error either way. Now a conflict means nothing
    /// moved, and retrying after clearing the conflict restores the whole set.
    ///
    /// An I/O failure partway through is still possible (a volume disappearing
    /// mid-restore); those are collected rather than thrown at first sight, so
    /// the remaining entries still get their chance, and the token is kept so
    /// the user can retry what's left.
    public func undo(_ token: UndoToken) async throws {
        if tokens[token.id] == nil {
            // Allow undoing a token loaded from disk on a later launch.
            try ingestFromDiskIfPresent(token.id)
            guard tokens[token.id] != nil else { throw DeletionError.unknownToken(token.id) }
        }

        // Preflight: nothing moves until every entry is known-restorable.
        for entry in token.entries {
            guard fm.fileExists(atPath: entry.staged.path) else {
                throw DeletionError.sourceMissing(entry.staged)
            }
            if fm.fileExists(atPath: entry.original.path) {
                throw DeletionError.originalReoccupied(entry.original)
            }
        }

        var restored = 0
        var failures: [String] = []
        for entry in token.entries {
            do {
                try fm.createDirectory(
                    at: entry.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: entry.staged, to: entry.original)
                restored += 1
            } catch {
                failures.append("\(entry.original.lastPathComponent): \(Self.shortReason(from: error))")
            }
        }

        await ActivityLog.shared.append(ActivityEntry(
            kind: .undo, source: .manual, bytes: token.totalBytes,
            itemCount: restored, tokenID: token.id,
            note: failures.isEmpty ? nil : "\(failures.count) item(s) could not be restored"))

        guard failures.isEmpty else {
            // Keep the token and its staging dir so the rest can be retried.
            throw DeletionError.ioFailure(
                underlying: "Restored \(restored) of \(token.entries.count). "
                    + failures.prefix(3).joined(separator: "; "))
        }

        // Best-effort cleanup of now-empty staging directory + on-disk token.
        try? fm.removeItem(at: token.stagingDir)
        try? fm.removeItem(at: tokenFile(for: token.id))
        tokens.removeValue(forKey: token.id)
    }

    /// Permanently delete everything in `token` — staging dir and on-disk record.
    public func empty(_ token: UndoToken) async throws {
        do {
            if fm.fileExists(atPath: token.stagingDir.path) {
                try fm.removeItem(at: token.stagingDir)
            }
            try? fm.removeItem(at: tokenFile(for: token.id))
            tokens.removeValue(forKey: token.id)
            await ActivityLog.shared.append(ActivityEntry(
                kind: .empty, source: .manual, bytes: token.totalBytes,
                itemCount: token.entries.count, tokenID: token.id))
        } catch {
            throw DeletionError.ioFailure(underlying: error.localizedDescription)
        }
    }

    /// Drop every staging directory and token. Used by Settings → "Empty staged
    /// trash now".
    public func emptyAll() async throws {
        let root = Self.rootStagingDir()
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        // Records live outside the Trash now, so clearing the staging root no
        // longer takes them with it.
        let records = Self.tokensDir()
        if fm.fileExists(atPath: records.path) {
            try? fm.removeItem(at: records)
        }
        tokens.removeAll()
    }

    /// Re-hydrate tokens from disk. Call once on app launch, before showing any
    /// undo affordance — without it, a token written by a previous launch is
    /// invisible to `allTokens()` and its staged files are stranded in the Trash.
    ///
    /// Tokens whose staging directory has since vanished (the user emptied the
    /// Trash in Finder) are dropped here rather than surfaced as undos that
    /// would fail with `sourceMissing`.
    public func loadPersistedTokens() async {
        migrateLegacyTokensIfPresent()

        let dir = Self.tokensDir()
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dir.path)
        } catch {
            // A missing directory is the normal first-run case. Anything else
            // means undo-across-relaunch is silently broken, which is worth a
            // line in the log rather than an empty list and no explanation.
            if fm.fileExists(atPath: dir.path) {
                NSLog("[DeletionService] cannot list \(dir.path): \(error.localizedDescription)")
            }
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let token = try? decoder.decode(UndoToken.self, from: data) else { continue }
            guard fm.fileExists(atPath: token.stagingDir.path) else {
                // Staged files are gone — the record is dead weight.
                try? fm.removeItem(at: url)
                continue
            }
            tokens[token.id] = token
        }
    }

    /// Move pre-1.0.5 records out of the Trash into Application Support.
    ///
    /// Best-effort by nature: listing the old directory is exactly the
    /// operation TCC blocks, so this recovers tokens only on machines that have
    /// granted Full Disk Access. There is no way to enumerate them otherwise —
    /// which is the whole reason the location changed.
    private func migrateLegacyTokensIfPresent() {
        let legacy = Self.legacyTokensDir()
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        let dest = Self.tokensDir()
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in names where name.hasSuffix(".json") {
            let from = legacy.appendingPathComponent(name)
            let to = dest.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try? fm.moveItem(at: from, to: to)
        }
    }

    public func allTokens() async -> [UndoToken] {
        Array(tokens.values).sorted { $0.createdAt > $1.createdAt }
    }

    /// Look up a known token by id — for undoing straight from an Activity Log
    /// entry, which stores only the `tokenID`.
    public func token(id: UUID) async -> UndoToken? {
        if let token = tokens[id] { return token }
        // Read-through, deliberately without caching: `isRestorable` asks this
        // question about tokens that may be dead, and an existence check has no
        // business resurrecting one into the live map.
        return readTokenFile(id)
    }

    /// Whether `id` can still be restored: we know the token and its staged
    /// files are still on disk.
    public func isRestorable(_ id: UUID) async -> Bool {
        guard let token = await token(id: id) else { return false }
        return fm.fileExists(atPath: token.stagingDir.path)
    }

    /// Restore by id. Convenience over ``undo(_:)`` for call sites that only
    /// hold an `ActivityEntry.tokenID`.
    public func undo(id: UUID) async throws {
        guard let token = await token(id: id) else {
            throw DeletionError.unknownToken(id)
        }
        // undo(_:) resolves through the in-memory map, so adopt it first.
        tokens[token.id] = token
        try await undo(token)
    }

    // MARK: - Retention

    /// How long staged files stay restorable before ``sweepExpiredTokens(olderThanDays:now:)``
    /// removes them for good. The user can still empty the Trash sooner — this
    /// is an upper bound on how long we hold their disk space, not a guarantee
    /// the files survive that long.
    public static let retentionDays = 30

    /// Permanently delete staging directories older than the retention window
    /// and forget their tokens. Call at launch, after `loadPersistedTokens()`.
    ///
    /// Each removal is recorded in the Activity Log — a sweep destroys user data,
    /// so it belongs in the audit trail just like a manual "empty".
    /// Returns the number of tokens swept.
    @discardableResult
    public func sweepExpiredTokens(olderThanDays days: Int = DeletionService.retentionDays,
                                   now: Date = Date()) async -> Int {
        let cutoff = Double(days) * 86_400
        var swept = 0
        // Snapshot first — the loop mutates `tokens`.
        let due = Array(tokens.values).filter { now.timeIntervalSince($0.createdAt) >= cutoff }
        for token in due {
            try? fm.removeItem(at: token.stagingDir)
            try? fm.removeItem(at: tokenFile(for: token.id))
            tokens.removeValue(forKey: token.id)
            swept += 1
            await ActivityLog.shared.append(ActivityEntry(
                kind: .empty, source: .system, bytes: token.totalBytes,
                itemCount: token.entries.count, tokenID: token.id,
                note: "Retention window elapsed (\(days) days)"))
        }
        return swept
    }

    // MARK: - Internals

    private func newStagingDir(id: UUID) throws -> URL {
        let root = Self.rootStagingDir()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueDestination(in dir: URL, for source: URL) -> URL {
        let base = source.lastPathComponent
        var candidate = dir.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(n))")
            n += 1
        }
        return candidate
    }

    private func persist(_ token: UndoToken) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = Self.tokensDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(token)
        try data.write(to: tokenFile(for: token.id), options: .atomic)
    }

    /// Decode a token record from disk without touching in-memory state.
    private func readTokenFile(_ id: UUID) -> UndoToken? {
        let url = tokenFile(for: id)
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UndoToken.self, from: data)
    }

    /// Load a token from disk into the in-memory map, for callers that are
    /// about to act on it.
    @discardableResult
    private func ingestFromDiskIfPresent(_ id: UUID) throws -> UndoToken? {
        guard let token = readTokenFile(id) else { return nil }
        tokens[token.id] = token
        return token
    }

    private func tokenFile(for id: UUID) -> URL {
        Self.tokensDir().appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Filesystem layout

    static func rootStagingDir() -> URL {
        let trash = FileManager.default
            .urls(for: .trashDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        return trash.appendingPathComponent("MacCleanerPro", isDirectory: true)
    }

    /// Where undo *records* live — deliberately NOT inside the Trash.
    ///
    /// macOS gates directory enumeration of `~/.Trash` behind Full Disk Access:
    /// `fileExists`, reads, writes and deletes on a known path all succeed, but
    /// `contentsOfDirectory` throws "you don't have permission to view it".
    /// While the records lived in `rootStagingDir()/tokens`, `loadPersistedTokens()`
    /// silently found nothing on any Mac that hadn't granted FDA yet — so undo
    /// across a relaunch quietly did nothing, which is the one thing it exists
    /// to do. Application Support is enumerable unconditionally.
    ///
    /// The staged *files* stay in the Trash; only the bookkeeping moved.
    static func tokensDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacCleanerPro/undo-tokens",
                                    isDirectory: true)
    }

    /// Pre-1.0.5 location, inside the Trash. Read once on launch so an upgrade
    /// doesn't strand tokens written by an older build.
    static func legacyTokensDir() -> URL {
        rootStagingDir().appendingPathComponent("tokens", isDirectory: true)
    }

    static func allocatedSize(of url: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory == true {
            var total: UInt64 = 0
            // No .skipsHiddenFiles: we moved the directory whole, hidden
            // children included, so the byte count has to include them too —
            // otherwise the Activity Log under-reports what was reclaimed.
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys)
            ) {
                for case let child as URL in enumerator {
                    if let s = try? child.resourceValues(forKeys: keys).totalFileAllocatedSize {
                        total &+= UInt64(s)
                    }
                }
            }
            return total
        } else {
            return UInt64(values.totalFileAllocatedSize ?? 0)
        }
    }
}

// `URL` is `Codable` only when encoded in a relative form by default — for our
// absolute filesystem URLs the default behavior is what we want, so no custom
// coding shim is needed.
