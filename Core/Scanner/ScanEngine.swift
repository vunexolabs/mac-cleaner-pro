import Foundation

/// One scanned filesystem entry under a rule.
public struct ScanItem: Sendable, Hashable {
    public let url: URL
    public let size: UInt64
    public let modifiedAt: Date?
    public init(url: URL, size: UInt64, modifiedAt: Date?) {
        self.url = url; self.size = size; self.modifiedAt = modifiedAt
    }
}

/// Live progress events emitted by ``ScanEngine`` while the scan runs.
///
/// The UI subscribes to these to render a real-time scanner view (current
/// rule, accumulated bytes / file count, sampled file paths) — no fake
/// canned animation.
public enum ScanEvent: Sendable {
    /// A rule has just started scanning.
    case ruleStarted(ruleID: String, displayName: String, index: Int, total: Int)
    /// A file was sampled. Emitted at a throttled rate so the UI's "live
    /// stream" panel can show real paths flying by without spamming.
    case fileSampled(path: String, size: UInt64)
    /// Cumulative running totals across the whole scan.
    case progress(bytesScanned: UInt64, filesScanned: Int)
    /// A rule finished. The UI can mark it green and move on.
    case ruleCompleted(ruleID: String, displayName: String, totalBytes: UInt64, itemCount: Int)
}

/// Aggregated result for a single rule.
public struct RuleScanResult: Sendable, Identifiable {
    public let ruleID: String
    public let displayName: String
    public let category: RulePack.Category
    public let safety: RulePack.Safety
    public let requiresHelper: Bool
    public let items: [ScanItem]
    public let totalSize: UInt64
    public let error: String?
    /// Mirrors the rule's `restoreHint` so the UI can show "how to get it back".
    public let restoreHint: String?

    public var id: String { ruleID }

    public init(ruleID: String,
                displayName: String,
                category: RulePack.Category,
                safety: RulePack.Safety,
                requiresHelper: Bool,
                items: [ScanItem],
                totalSize: UInt64,
                error: String? = nil,
                restoreHint: String? = nil) {
        self.ruleID = ruleID
        self.displayName = displayName
        self.category = category
        self.safety = safety
        self.requiresHelper = requiresHelper
        self.items = items
        self.totalSize = totalSize
        self.error = error
        self.restoreHint = restoreHint
    }
}

/// Executes rules from a `RulePack` in parallel.
///
/// Helper-required rules currently produce a deferred result with a zero size and
/// a `requiresHelper` flag the UI can act on; size summation through the helper's
/// `sizesForSystemPaths` is wired in once SMAppService approval is in hand.
public actor ScanEngine {

    private let resolver = PathResolver()

    public init() {}

    public func scan(pack: RulePack) async -> [RuleScanResult] {
        await scan(pack: pack, onEvent: nil)
    }

    /// Streaming variant. `onEvent` is called from a background actor, so
    /// callers should hop to `MainActor` before mutating any `@Published` state.
    /// Sample paths and progress events are throttled inside the engine to
    /// keep callback volume well under 100 Hz even on fast SSDs.
    public func scan(
        pack: RulePack,
        onEvent: (@Sendable (ScanEvent) -> Void)?
    ) async -> [RuleScanResult] {
        let rules = pack.rules
        let total = rules.count
        // Shared running counters across all parallel rule scanners. We use
        // an actor-encapsulated mutable struct because the task group's child
        // tasks may emit `progress` events concurrently.
        let aggregator = ProgressAggregator(emitter: onEvent)

        return await withTaskGroup(of: RuleScanResult.self, returning: [RuleScanResult].self) { group in
            for (idx, rule) in rules.enumerated() {
                group.addTask { [resolver] in
                    await aggregator.ruleStarted(
                        ruleID: rule.id,
                        displayName: rule.displayName,
                        index: idx,
                        total: total
                    )
                    let result = await Self.scanOne(
                        rule: rule,
                        resolver: resolver,
                        aggregator: aggregator
                    )
                    await aggregator.ruleCompleted(
                        ruleID: rule.id,
                        displayName: rule.displayName,
                        totalBytes: result.totalSize,
                        itemCount: result.items.count
                    )
                    return result
                }
            }
            var out: [RuleScanResult] = []
            for await result in group { out.append(result) }
            // Sort by reclaimable size descending so the UI shows wins first.
            out.sort { $0.totalSize > $1.totalSize }
            return out
        }
    }

    private static func scanOne(
        rule: RulePack.Rule,
        resolver: PathResolver,
        aggregator: ProgressAggregator? = nil
    ) async -> RuleScanResult {
        if rule.requiresHelper {
            return RuleScanResult(
                ruleID: rule.id,
                displayName: rule.displayName,
                category: rule.category,
                safety: rule.safety,
                requiresHelper: true,
                items: [],
                totalSize: 0,
                restoreHint: rule.restoreHint
            )
        }

        let roots = resolver.resolve(patterns: rule.paths, excludes: rule.excludes ?? [])
        let cutoff = rule.olderThanDays.map { Date(timeIntervalSinceNow: -Double($0) * 86_400) }

        var items: [ScanItem] = []
        var total: UInt64 = 0

        for root in roots {
            if Task.isCancelled { break }
            let (size, mtime) = await sizeAndModified(of: root, aggregator: aggregator)
            if let cutoff, let mtime, mtime > cutoff { continue }
            items.append(ScanItem(url: root, size: size, modifiedAt: mtime))
            total &+= size
            // Emit a sample for the root path itself (so even shallow scans
            // produce something for the UI's stream).
            await aggregator?.fileSampled(path: root.path, size: size)
        }

        return RuleScanResult(
            ruleID: rule.id,
            displayName: rule.displayName,
            category: rule.category,
            safety: rule.safety,
            requiresHelper: false,
            items: items.sorted { $0.size > $1.size },
            totalSize: total,
            restoreHint: rule.restoreHint
        )
    }

    /// Total file-allocated size + most-recent mtime of `url`. Recurses into
    /// directories using `FileManager.enumerator`.
    ///
    /// Hidden children are counted. Cleaning moves each root directory whole,
    /// so excluding dotfiles here would report less than the clean actually
    /// reclaims — and cache trees are full of them (`.lock`, `.cache`, and the
    /// dot-prefixed subtrees npm and Gradle keep).
    private static func sizeAndModified(
        of url: URL,
        aggregator: ProgressAggregator? = nil
    ) async -> (UInt64, Date?) {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .isDirectoryKey, .contentModificationDateKey
        ]
        let values = (try? url.resourceValues(forKeys: Set(keys)))
        guard let values else { return (0, nil) }

        if values.isDirectory == true {
            var total: UInt64 = 0
            var newest = values.contentModificationDate
            var counter: Int = 0
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: keys
            ) {
                for case let child as URL in enumerator {
                    if Task.isCancelled { break }
                    let r = try? child.resourceValues(forKeys: Set(keys))
                    let childSize = UInt64(r?.totalFileAllocatedSize ?? 0)
                    if childSize > 0 { total &+= childSize }
                    if let m = r?.contentModificationDate {
                        if newest.map({ m > $0 }) ?? true { newest = m }
                    }
                    counter &+= 1
                    // Mid-walk path sample roughly every 128 files — purely
                    // for the UI's live-stream panel. Awaited straight through
                    // to the aggregator: a detached task per sample spawned
                    // thousands of one-shot tasks on a large scan. We don't emit
                    // progress updates here to avoid double-counting with the
                    // per-root delta below.
                    if let aggregator, counter % 128 == 0 {
                        await aggregator.fileSampled(path: child.path, size: childSize)
                    }
                }
            }
            // Single delta per root — accurate, no double counting.
            await aggregator?.deltaProgress(addBytes: total, addFiles: counter)
            return (total, newest)
        } else {
            // Single file root.
            let bytes = UInt64(values.totalFileAllocatedSize ?? 0)
            await aggregator?.deltaProgress(addBytes: bytes, addFiles: 1)
            return (bytes, values.contentModificationDate)
        }
    }
}

// MARK: - Progress aggregator

/// Actor-isolated counter shared across parallel rule scanners. Throttles
/// `progress` events so the UI receives at most ~10 per second per rule.
actor ProgressAggregator {
    private var totalBytes: UInt64 = 0
    private var totalFiles: Int = 0
    private var lastEmit: Date = .distantPast
    private let emitter: (@Sendable (ScanEvent) -> Void)?

    init(emitter: (@Sendable (ScanEvent) -> Void)?) {
        self.emitter = emitter
    }

    func ruleStarted(ruleID: String, displayName: String, index: Int, total: Int) {
        emitter?(.ruleStarted(ruleID: ruleID, displayName: displayName, index: index, total: total))
    }

    func ruleCompleted(ruleID: String, displayName: String, totalBytes: UInt64, itemCount: Int) {
        emitter?(.ruleCompleted(ruleID: ruleID, displayName: displayName,
                                totalBytes: totalBytes, itemCount: itemCount))
        // Flush a final progress snapshot so the UI lands on accurate totals.
        emitter?(.progress(bytesScanned: self.totalBytes, filesScanned: self.totalFiles))
    }

    /// Emits a sampled path; never throttled — sampling is done at the source.
    func fileSampled(path: String, size: UInt64) {
        emitter?(.fileSampled(path: path, size: size))
    }

    /// Adds an incremental delta to running totals and emits a throttled
    /// `progress` event (max ~10 Hz).
    func deltaProgress(addBytes: UInt64, addFiles: Int) {
        totalBytes &+= addBytes
        totalFiles &+= addFiles
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= 0.10 {
            lastEmit = now
            emitter?(.progress(bytesScanned: totalBytes, filesScanned: totalFiles))
        }
    }
}
