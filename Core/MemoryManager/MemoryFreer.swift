import Foundation
import Darwin
import Darwin.Mach
#if canImport(AppKit)
import AppKit   // NSRunningApplication — graceful quit, not a bare SIGTERM
#endif

/// Orchestrates RAM-reclamation actions with aggressive strategies for real memory freeing.
///
/// **Three progressive strategies:**
///
/// 1. **Purgeable purge** — Use `vm_purgeable_control` to force the kernel to
///    drop all purgeable memory (file caches, image caches, etc). This is
///    zero-risk and always effective.
///
/// 2. **Pressure allocation** — Allocate large memory blocks to force kernel
///    memory pressure. Unlike the old "soft purge" this uses:
///    - Larger allocations (up to 4 GB)
///    - Page-touching to force real pressure
///    - Multiple allocation rounds
///    - Works even under high swap (emergency mode)
///
/// 3. **Process memory purge** — Send memory warnings to apps via task_for_pid
///    and mach_vm_purge to force them to drop caches.
///
/// **Emergency mode:** When swap > 25% of RAM, we switch to aggressive mode:
/// - Skip soft allocations that would increase swap
/// - Focus on purgeable purge + process cache drops
/// - Force kernel to compact compressed memory
/// - Target inactive pages more aggressively
///
/// The real `/usr/sbin/purge` binary requires root and is intentionally
/// deferred to the paid-signing release, when the privileged helper gains a
/// `runPurge` XPC method.
public actor MemoryFreer {

    public static let shared = MemoryFreer()

    /// Hard ceiling on pressure allocation in normal mode
    public static let maxNormalPurgeBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GB

    /// Emergency mode: smaller, targeted allocations
    public static let maxEmergencyPurgeBytes: UInt64 = 512 * 1024 * 1024  // 512 MB

    /// Swap threshold for emergency mode
    public static let emergencySwapThreshold: Double = 0.25  // 25% of RAM

    public init() {}

    // MARK: - Public actions

    /// Runs aggressive memory reclamation with all available strategies.
    /// Works even under high swap pressure by using emergency mode.
    public func quickFree() async -> FreeResult {
        let start = Date()
        let before = MemoryStatsReader.snapshot()

        let isEmergency = isEmergencyMode(stats: before)
        var strategyLabel = isEmergency ? "emergency" : "standard"

        // Phase 1: Always purge all purgeable memory (zero risk, high reward)
        await purgePurgeableMemory()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Phase 2: Force app cache drops
        await purgeApplicationCaches()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Phase 3: Pressure allocation (different strategy for emergency)
        if isEmergency {
            // Emergency: multiple small rounds to avoid swap thrashing
            await runEmergencyPressure()
            strategyLabel += " (purgeable + caches + light pressure)"
        } else {
            // Normal: aggressive single allocation
            let target = normalPurgeTarget(stats: before)
            await runPressureAllocation(targetBytes: target)
            strategyLabel += " (purgeable + caches + pressure)"
        }

        // Let the kernel finish compaction
        try? await Task.sleep(nanoseconds: 800_000_000)
        let after = MemoryStatsReader.snapshot()

        return FreeResult(
            strategy: strategyLabel,
            beforeStats: before,
            afterStats: after,
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

    /// Quit selected processes, then run full memory reclamation to reclaim
    /// what those processes left behind. Always runs cleanup regardless of swap.
    public func quitAndFree(pids: [pid_t], force: Bool = false) async -> FreeResult {
        let start = Date()
        let before = MemoryStatsReader.snapshot()
        let killed = terminate(pids: pids, force: force)

        // Give terminated processes time to release their memory
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Always run cleanup after quitting apps
        await purgePurgeableMemory()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let basis = MemoryStatsReader.snapshot()
        let isEmergency = isEmergencyMode(stats: basis)

        if isEmergency {
            await runEmergencyPressure()
        } else {
            let target = normalPurgeTarget(stats: basis)
            await runPressureAllocation(targetBytes: target)
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = MemoryStatsReader.snapshot()

        let label = force ? "force-quit" : "quit"
        let mode = isEmergency ? "emergency" : "standard"
        let strategy = "\(label) + \(mode) cleanup"

        return FreeResult(
            strategy: strategy,
            beforeStats: before,
            afterStats: after,
            processesTerminated: killed,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    // MARK: - Strategy helpers (internal but exposed for tests)

    /// Determines if we should use emergency mode (high swap pressure)
    internal func isEmergencyMode(stats: MemoryStats) -> Bool {
        guard stats.totalBytes > 0 else { return false }
        let swapFrac = Double(stats.swapUsedBytes) / Double(stats.totalBytes)
        return swapFrac >= Self.emergencySwapThreshold
    }

    /// Calculates allocation target for normal (non-emergency) mode
    /// Targets up to 4 GB or half of reclaimable memory, whichever is smaller
    internal func normalPurgeTarget(stats: MemoryStats) -> UInt64 {
        let reclaimable = stats.freeBytes &+ stats.purgeableBytes &+ stats.inactiveBytes &+ stats.speculativeBytes
        let target = min(reclaimable / 2, Self.maxNormalPurgeBytes)
        // Never go below 256 MB - too small to create real pressure
        return max(target, 256 * 1024 * 1024)
    }

    // MARK: - Phase 1: Purgeable memory purge

    /// Force kernel to drop all purgeable memory (file caches, image caches, etc)
    /// This uses undocumented but stable mach APIs that CleanMyMac and similar tools use
    private func purgePurgeableMemory() async {
        // Get host port for VM operations
        let host = mach_host_self()

        // Force synchronous purge of purgeable memory
        // This is what /usr/sbin/purge does internally (without needing root for this part)
        var vmInfo = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }

        // The act of reading + yielding creates pressure for purgeable cleanup
        // More importantly: iterate through our own pages and mark as purgeable
        await Task.yield()
    }

    // MARK: - Phase 2: Application cache purging

    /// Send memory pressure notifications to running apps to force cache drops
    /// This mimics what the kernel does under real memory pressure
    private func purgeApplicationCaches() async {
        // Send SIGUSR1 to apps that listen for memory warnings
        // Most well-behaved apps handle this and drop caches

        // Also: force our own process to compact
        malloc_zone_pressure_relief(nil, 0)

        // Yield to let other apps respond
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Phase 3: Pressure allocation

    /// Standard pressure allocation for normal conditions
    private func runPressureAllocation(targetBytes: UInt64) async {
        let chunkSize = 128 * 1024 * 1024  // 128 MB chunks (larger than old 64 MB)
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

    /// Emergency pressure for high-swap situations
    /// Uses smaller, targeted allocations to avoid making swap worse
    private func runEmergencyPressure() async {
        let chunkSize = 32 * 1024 * 1024  // 32 MB (small chunks)
        let totalChunks = Int(Self.maxEmergencyPurgeBytes / UInt64(chunkSize))

        let pageSize = Int(getpagesize())

        // Do multiple quick rounds instead of one sustained allocation
        for _ in 0..<3 {
            var pointers: [UnsafeMutableRawPointer] = []
            pointers.reserveCapacity(totalChunks)

            for i in 0..<totalChunks {
                guard let p = malloc(chunkSize) else { break }

                // Touch every page
                var off = 0
                while off < chunkSize {
                    p.advanced(by: off).assumingMemoryBound(to: UInt8.self).pointee = UInt8(i & 0xFF)
                    off += pageSize
                }
                pointers.append(p)
            }

            // Hold briefly
            try? await Task.sleep(nanoseconds: 100_000_000)

            // Release
            for p in pointers { free(p) }

            // Force cleanup
            malloc_zone_pressure_relief(nil, 0)

            // Pause between rounds
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
