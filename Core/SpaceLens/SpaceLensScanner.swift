import Foundation

/// One node in the Space Lens directory tree.
///
/// `children` is sorted by `size` descending after a scan completes. A leaf
/// (`isDirectory == false`) has no children. Bundles like `.app`, `.framework`,
/// and `.bundle` are treated as leaves with their full directory size — matches
/// how Finder reports them.
public struct SpaceLensNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let size: UInt64
    public let isDirectory: Bool
    public let children: [SpaceLensNode]

    public init(url: URL, name: String, size: UInt64, isDirectory: Bool, children: [SpaceLensNode]) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Walks a directory tree and produces a sized `SpaceLensNode` tree suitable
/// for treemap visualization. Honors cancellation, and counts hidden entries so
/// the totals agree with Finder's.
public actor SpaceLensScanner {

    /// Snapshot delivered to subscribers as the scan progresses. Lets the UI
    /// show running totals + the current path being walked.
    public struct Progress: Sendable {
        public let bytesScanned: UInt64
        public let currentPath: String
    }

    public init() {}

    /// Performs a full recursive walk. `onProgress` is called from a background
    /// actor — callers should hop to MainActor before mutating UI state.
    public func scan(
        root: URL,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> SpaceLensNode {
        let counter = Counter()
        return await Self.walk(url: root, counter: counter, onProgress: onProgress)
    }

    /// Mutable counter passed through the recursion so we can throttle progress
    /// emission without going through the actor on every file.
    private final class Counter: @unchecked Sendable {
        var bytes: UInt64 = 0
        var lastEmit: Date = .distantPast
    }

    private static func walk(
        url: URL,
        counter: Counter,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async -> SpaceLensNode {
        if Task.isCancelled {
            return SpaceLensNode(url: url, name: url.lastPathComponent,
                                 size: 0, isDirectory: true, children: [])
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .totalFileAllocatedSizeKey,
            .isPackageKey, .isSymbolicLinkKey,
        ]
        let values = (try? url.resourceValues(forKeys: Set(keys)))
        let isDir = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        let isSymlink = values?.isSymbolicLink == true

        // Bundles and non-directories are leaf nodes sized as a whole.
        if !isDir || isPackage || isSymlink {
            let size: UInt64
            if isPackage || isSymlink {
                size = directoryAllocatedSize(of: url)
            } else {
                size = UInt64(values?.totalFileAllocatedSize ?? 0)
            }
            counter.bytes &+= size
            emit(counter: counter, path: url.path, onProgress: onProgress)
            return SpaceLensNode(url: url, name: url.lastPathComponent,
                                 size: size, isDirectory: false, children: [])
        }

        // Recurse.
        // Hidden entries are included: a directory's size is the sum of its
        // children, so skipping dotfiles would make every ancestor total read
        // low — and the dot-prefixed caches under ~/Library and ~/ are often
        // exactly the space the user came here to find.
        var children: [SpaceLensNode] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys
        ) {
            for child in contents {
                if Task.isCancelled { break }
                let node = await walk(url: child, counter: counter, onProgress: onProgress)
                if node.size > 0 { children.append(node) }
            }
        }

        children.sort { $0.size > $1.size }
        let total = children.reduce(UInt64(0)) { $0 &+ $1.size }
        return SpaceLensNode(url: url, name: url.lastPathComponent,
                             size: total, isDirectory: true, children: children)
    }

    /// Recursively totals the allocated bytes inside a directory (or bundle).
    /// Used for `.app`, `.framework`, and symlink leaves where we don't want to
    /// expand children but still want a meaningful size.
    ///
    /// Counts hidden children: a bundle's dot-prefixed internals are real bytes
    /// on disk, and a size that disagrees with Finder's is worse than useless in
    /// a tool whose whole job is accounting for space.
    private static func directoryAllocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        var total: UInt64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys
        ) else { return 0 }
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            let v = try? child.resourceValues(forKeys: Set(keys))
            total &+= UInt64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Throttled progress emission — at most ~10 events per second.
    private static func emit(
        counter: Counter,
        path: String,
        onProgress: (@Sendable (Progress) -> Void)?
    ) {
        guard let onProgress else { return }
        let now = Date()
        if now.timeIntervalSince(counter.lastEmit) >= 0.10 {
            counter.lastEmit = now
            onProgress(Progress(bytesScanned: counter.bytes, currentPath: path))
        }
    }
}
