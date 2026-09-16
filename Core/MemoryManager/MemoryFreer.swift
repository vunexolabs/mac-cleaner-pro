import Foundation
import Darwin
import Darwin.Mach
#if canImport(AppKit)
import AppKit   // NSRunningApplication — graceful quit, not a bare SIGTERM
#endif

/// RAM reclamation, and an honest account of what that can mean without root.
///
/// **There is exactly one mechanism here: pressure allocation.** We allocate a
/// large block, touch every page so the kernel must actually back it, hold it
/// briefly, then release. That forces the kernel to evict its least-valuable
/// pages first — file-backed caches and inactive pages — which is what makes
/// "available memory" climb afterwards.
///
/// **What that costs.** Those evicted pages were mostly useful file cache. The
/// number goes up; the next read of an evicted file goes to disk. This is worth
/// doing when something is about to need a large contiguous chunk of RAM, and
/// it is not worth doing habitually. `FreeResult.reclaimedBytes` measures the
/// drop in (cached + inactive) — i.e. what we evicted — and deliberately not
/// the change in `availableBytes`, which would flatter the result.
///
/// **Under swap pressure we do nothing.** Once swap exceeds
/// ``emergencySwapThreshold`` of RAM, allocating more pages makes the thrashing
/// worse, so `quickFree` skips the allocation and reports why in
/// `FreeResult.skippedReason`. The useful action on a swapping Mac is quitting
/// something, not asking the kernel to shuffle pages.
///
/// **What is deliberately absent.** Earlier revisions advertised a purgeable
/// purge via `vm_purgeable_control` and per-app cache drops via `task_for_pid` /
/// `mach_vm_purge`. Neither was implemented — one read VM statistics and
/// yielded, the other called `malloc_zone_pressure_relief` on *our own* heap —
/// so both were removed rather than left to imply capability we lack. Real
/// purging is `/usr/sbin/purge`, which needs root; it is deferred to the
/// paid-signing release, when the privileged helper gains a `runPurge` XPC
/// method.
public actor MemoryFreer {

    public static let shared = MemoryFreer()

    /// Hard ceiling on pressure allocation in normal mode
    public static let maxNormalPurgeBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GB

    /// Swap threshold for emergency mode
    public static let emergencySwapThreshold: Double = 0.25  // 25% of RAM

    public init() {}

    // MARK: - Public actions

    /// Evict cached and inactive pages by applying memory pressure — unless the
    /// machine is already swapping, in which case doing so would make things
    /// worse and we say so instead.
    public func quickFree() async -> FreeResult {
        let start = Date()
        let before = MemoryStatsReader.snapshot()

        guard !isEmergencyMode(stats: before) else {
            return FreeResult(
                strategy: "no action (swapping)",
                beforeStats: before,
                afterStats: MemoryStatsReader.snapshot(),
                processesTerminated: 0,
                elapsed: Date().timeIntervalSince(start),
                skippedReason: "Your Mac is already using swap. Allocating memory to "
                    + "force the kernel to drop caches would add to the paging it is "
                    + "already doing. Quit something you aren't using instead."
            )
        }

        await runPressureAllocation(targetBytes: normalPurgeTarget(stats: before))

        // Let the kernel finish reclaiming before we measure.
        try? await Task.sleep(nanoseconds: 800_000_000)

        return FreeResult(
            strategy: "cache eviction under pressure",
            beforeStats: before,
            afterStats: MemoryStatsReader.snapshot(),
            processesTerminated: 0,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    /// Asks each pid to quit, preferring the graceful path. Returns the count
    /// successfully asked.
    ///
    /// For a GUI app we go through `NSRunningApplication.terminate()`, which
    /// sends the same Apple Event ⌘Q does: the app gets to flush state and put
    /// up its "save changes?" sheet. Signalling `SIGTERM` straight at a Cocoa
    /// app skips all of that — most AppKit apps have no `SIGTERM` handler, so
    /// the process dies where it stands and unsaved documents go with it. A
    /// RAM-cleanup button is not worth someone's unsaved work.
    ///
    /// `force` is the escape hatch for an app that ignores the polite request:
    /// `forceTerminate()` (SIGKILL under the hood) with no chance to save. The
    /// UI must make that distinction explicit before calling this.
    ///
    /// Non-GUI processes have no NSRunningApplication, so they still get a
    /// signal — `SIGTERM` by default, which well-behaved daemons do handle.
    public func terminate(pids: [pid_t], force: Bool = false) -> Int {
        var ok = 0
        for pid in pids where pid > 0 {
            if terminateOne(pid: pid, force: force) { ok += 1 }
        }
        return ok
    }

    private func terminateOne(pid: pid_t, force: Bool) -> Bool {
        #if canImport(AppKit)
        if let app = NSRunningApplication(processIdentifier: pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        #endif
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }

    /// Ask the given processes to quit, then reclaim what they released.
    ///
    /// Quitting is the part that genuinely returns memory; the pressure pass
    /// afterwards only evicts caches, and is skipped on a swapping machine for
    /// the same reason `quickFree` skips it.
    public func quitAndFree(pids: [pid_t], force: Bool = false) async -> FreeResult {
        let start = Date()
        let before = MemoryStatsReader.snapshot()
        let asked = terminate(pids: pids, force: force)

        // Give the apps a moment to wind down and release their pages.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let basis = MemoryStatsReader.snapshot()
        let label = force ? "force-quit" : "quit"

        guard !isEmergencyMode(stats: basis) else {
            return FreeResult(
                strategy: "\(label) only (swapping)",
                beforeStats: before,
                afterStats: basis,
                processesTerminated: asked,
                elapsed: Date().timeIntervalSince(start),
                skippedReason: "Skipped the cache-eviction pass: your Mac is still "
                    + "swapping, and allocating memory now would add to the paging."
            )
        }

        await runPressureAllocation(targetBytes: normalPurgeTarget(stats: basis))
        try? await Task.sleep(nanoseconds: 500_000_000)

        return FreeResult(
            strategy: "\(label) + cache eviction",
            beforeStats: before,
            afterStats: MemoryStatsReader.snapshot(),
            processesTerminated: asked,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Strategy helpers (internal but exposed for tests)

    /// True when the machine is already paging hard enough that adding memory
    /// pressure of our own would make it worse.
    internal func isEmergencyMode(stats: MemoryStats) -> Bool {
        guard stats.totalBytes > 0 else { return false }
        let swapFrac = Double(stats.swapUsedBytes) / Double(stats.totalBytes)
        return swapFrac >= Self.emergencySwapThreshold
    }

    /// How much to allocate: half of what looks reclaimable, capped at 4 GB.
    /// Half, not all, so we prod the kernel into evicting caches rather than
    /// racing it for the last free page.
    internal func normalPurgeTarget(stats: MemoryStats) -> UInt64 {
        let reclaimable = stats.freeBytes &+ stats.purgeableBytes &+ stats.inactiveBytes &+ stats.speculativeBytes
        let target = min(reclaimable / 2, Self.maxNormalPurgeBytes)
        // Never go below 256 MB - too small to create real pressure
        return max(target, 256 * 1024 * 1024)
    }

    // MARK: - Pressure allocation

    /// Allocate, touch every page so the kernel must really back it, hold
    /// briefly, release. The touching is what makes this work: an untouched
    /// `malloc` is just address space and applies no pressure at all.
    private func runPressureAllocation(targetBytes: UInt64) async {
        let chunkSize = 128 * 1024 * 1024
        let totalChunks = Int(min(targetBytes / UInt64(chunkSize), 128))
        guard totalChunks > 0 else { return }

        let pageSize = Int(getpagesize())
        var pointers: [UnsafeMutableRawPointer] = []
        pointers.reserveCapacity(totalChunks)

        // Allocate in rounds to create sustained pressure
        let roundSize = 8
        for round in stride(from: 0, to: totalChunks, by: roundSize) {
            let end = min(round + roundSize, totalChunks)

            for i in round..<end {
                guard let p = malloc(chunkSize) else { break }

                // Touch every page to force real allocation
                var off = 0
                while off < chunkSize {
                    p.advanced(by: off).assumingMemoryBound(to: UInt8.self).pointee = UInt8(i & 0xFF)
                    off += pageSize
                }
                pointers.append(p)
            }

            // Brief yield between rounds to let kernel respond
            if round + roundSize < totalChunks {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // Hold the memory briefly to sustain pressure
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Release all at once
        for p in pointers { free(p) }

        // Force malloc zones to release back to system
        malloc_zone_pressure_relief(nil, 0)
    }
}
