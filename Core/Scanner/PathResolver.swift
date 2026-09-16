import Foundation

/// Resolves a rule's path patterns to concrete file/directory URLs.
///
/// Supported syntax in a single path string:
///   - Leading `~/` expands to the current user's home directory.
///   - A path segment of `*` matches any direct child of the parent, hidden
///     children included.
///   - A path segment of `**` matches zero or more directory levels (recursive),
///     descending into hidden directories too.
///   - All other segments are treated as literals.
///
/// Hidden entries used to be skipped by both wildcards. That silently excluded
/// real reclaimable data: every rule that wildcards into a cache tree
/// (`~/Library/Caches/*`, `.../DerivedData/*`, the browser profiles) missed the
/// dot-prefixed children sitting right next to the ones it matched, and a
/// directory the scanner *did* match was deleted whole anyway — hidden contents
/// and all. Matching them makes what a rule selects agree with what cleaning it
/// actually removes.
///
/// This widens what a wildcard selects, so two things stay true by design: a
/// rule's `excludes` are applied after expansion and still win, and package
/// contents are never descended into (`.skipsPackageDescendants` below), so a
/// `**` never walks inside a `.app`.
///
/// `**` is restricted to "directory recursion" semantics — the next segment after
/// `**` is what we're actually looking for. e.g. `~/Library/Logs/**/*` finds every
/// file or directory under any depth of `~/Library/Logs`.
public struct PathResolver: Sendable {

    public init() {}

    /// Resolve a list of pattern strings into concrete URLs that exist on disk.
    /// `excludes` are pattern strings too — any match (prefix-equal) is dropped.
    public func resolve(patterns: [String], excludes: [String] = []) -> [URL] {
        var results: [URL] = []
        for pattern in patterns {
            results.append(contentsOf: expand(pattern: pattern))
        }
        guard !excludes.isEmpty else { return dedupe(results) }

        let excludePrefixes = excludes
            .map { Self.expandTilde($0) }
            .map { ($0 as NSString).standardizingPath }

        let filtered = results.filter { url in
            let path = (url.path as NSString).standardizingPath
            return !excludePrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        return dedupe(filtered)
    }

    private func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = (url.path as NSString).standardizingPath
            if seen.insert(key).inserted { out.append(url) }
        }
        return out
    }

    private func expand(pattern: String) -> [URL] {
        let expanded = Self.expandTilde(pattern)
        let segments = expanded
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        // Absolute paths begin with an empty leading segment.
        let isAbsolute = expanded.hasPrefix("/")
        let startURL: URL = isAbsolute ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: ".")
        let working = isAbsolute ? Array(segments.dropFirst()) : segments

        return walk(remaining: working, current: startURL)
    }

    /// Recursive descent over the segment list, branching on `*`/`**`.
    private func walk(remaining: [String], current: URL) -> [URL] {
        guard let first = remaining.first else {
            return FileManager.default.fileExists(atPath: current.path) ? [current] : []
        }
        let rest = Array(remaining.dropFirst())

        switch first {
        case "":
            // Empty segment from a trailing slash: skip.
            return walk(remaining: rest, current: current)

        case "*":
            return childURLs(of: current).flatMap { walk(remaining: rest, current: $0) }

        case "**":
            // Match zero levels (consume `**` only) plus every descendant directory.
            var out = walk(remaining: rest, current: current)
            for descendant in directoriesRecursive(under: current) {
                out.append(contentsOf: walk(remaining: rest, current: descendant))
            }
            return out

        default:
            let next = current.appendingPathComponent(first)
            return walk(remaining: rest, current: next)
        }
    }

    private func childURLs(of dir: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        // `contentsOfDirectory` never yields "." or "..", so no filtering is
        // needed to stay inside `dir`.
        return names.map { dir.appendingPathComponent($0) }
    }

    private func directoriesRecursive(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(url)
            }
        }
        return dirs
    }

    static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = NSHomeDirectory()
            return home + String(path.dropFirst(1))
        }
        return path
    }
}
