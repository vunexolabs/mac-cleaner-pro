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
public actor DeletionService {

    public static let shared = DeletionService()

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
        let staging = try newStagingDir(id: id)
        var entries: [StagedEntry] = []
        var failures: [DeletionFailure] = []
        var total: UInt64 = 0

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

    /// Restore every entry in `token` to its original URL. Fails fast if the
    /// original location has been re-occupied — we never overwrite live state.
    public func undo(_ token: UndoToken) async throws {
        if tokens[token.id] == nil {
            // Allow undoing a token loaded from disk on a later launch.
            try ingestFromDiskIfPresent(token.id)
            guard tokens[token.id] != nil else { throw DeletionError.unknownToken(token.id) }
        }

        for entry in token.entries {
            guard fm.fileExists(atPath: entry.staged.path) else {
                throw DeletionError.sourceMissing(entry.staged)
            }
            if fm.fileExists(atPath: entry.original.path) {
                throw DeletionError.originalReoccupied(entry.original)
            }
            do {
                try fm.createDirectory(
                    at: entry.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: entry.staged, to: entry.original)
            } catch {
                throw DeletionError.ioFailure(underlying: error.localizedDescription)
            }
        }

        // Best-effort cleanup of now-empty staging directory + on-disk token.
        try? fm.removeItem(at: token.stagingDir)
        try? fm.removeItem(at: tokenFile(for: token.id))
        tokens.removeValue(forKey: token.id)
        await ActivityLog.shared.append(ActivityEntry(
            kind: .undo, source: .manual, bytes: token.totalBytes,
            itemCount: token.entries.count, tokenID: token.id))
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
        let dir = Self.tokensDir()
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
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

    public func allTokens() async -> [UndoToken] {
        Array(tokens.values).sorted { $0.createdAt > $1.createdAt }
    }

    /// Look up a known token by id — for undoing straight from an Activity Log
    /// entry, which stores only the `tokenID`.
    public func token(id: UUID) async -> UndoToken? {
        if let token = tokens[id] { return token }
        try? ingestFromDiskIfPresent(id)
        return tokens[id]
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

    private func ingestFromDiskIfPresent(_ id: UUID) throws {
        let url = tokenFile(for: id)
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let token = try decoder.decode(UndoToken.self, from: data)
        tokens[token.id] = token
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

    static func tokensDir() -> URL {
        rootStagingDir().appendingPathComponent("tokens", isDirectory: true)
    }

    static func allocatedSize(of url: URL) throws -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory == true {
            var total: UInt64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
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
