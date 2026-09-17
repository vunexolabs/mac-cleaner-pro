import Foundation

/// A point-in-time reading of a volume's capacity.
public struct DiskSpace: Sendable, Equatable {
    /// Total capacity of the volume, in bytes.
    public let totalBytes: UInt64
    /// What the system says is genuinely available to us — this accounts for
    /// purgeable space the OS would reclaim under pressure, which is why it can
    /// exceed the "free" figure Finder shows.
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// Saturating, so a volume reporting available > total (possible with
    /// purgeable space) never underflows into a nonsense figure.
    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes &- availableBytes : 0
    }

    /// 0…1. Zero when the volume's capacity is unknown rather than a divide by zero.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }
}

/// Reads volume capacity for the menu-bar readout.
///
/// Uses `volumeAvailableCapacityForImportantUsage`, not `volumeAvailableCapacity`:
/// the former is what macOS will actually let an app consume, including space
/// it would purge on demand, and it is the number Apple tells you to show a
/// user. The plain key under-reports on an APFS volume with purgeable content.
public enum DiskSpaceReader {

    /// Snapshot of `url`'s volume, or nil if the volume can't be interrogated
    /// (a disconnected mount, a path that no longer exists).
    public static func snapshot(for url: URL = URL(fileURLWithPath: "/")) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }

        return DiskSpace(
            totalBytes: UInt64(max(0, total)),
            availableBytes: UInt64(max(0, available))
        )
    }
}
