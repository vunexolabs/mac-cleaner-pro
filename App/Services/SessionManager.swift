import Foundation
import SwiftUI
import Core

/// Keeps memory monitoring running while the user is on another tab.
///
/// This used to also carry Space Lens and Large Files sessions, with pause,
/// resume and crash recovery — around 150 lines of it. No view ever read any
/// of it: every feature view owned a local @StateObject instead, so switching
/// tabs destroyed the view and threw away the scan. The scaffolding made it
/// look like that problem was already solved, which is why it went unnoticed.
///
/// Scan state now lives on the feature models themselves, which are shared
/// instances that outlive their views. What remains here is the memory session,
/// which is genuinely global and genuinely used.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    // MARK: - Memory Manager Session
    @Published var memoryStats: MemoryStats = MemoryStatsReader.snapshot()
    @Published var memoryPressure: MemoryPressureLevel = .normal
    @Published var memoryProcesses: [ProcessMemoryEntry] = []
    @Published var memoryTotalProcessCount: Int = 0

    private var memoryStatsTimer: Task<Void, Never>?
    private var memoryProcessTimer: Task<Void, Never>?
    private var memoryPressureMonitor: PressureMonitor?

    private init() {}

    // MARK: - Memory Manager

    func startMemoryMonitoring() {
        guard memoryStatsTimer == nil else { return }

        // Stats timer: 1Hz
        memoryStatsTimer = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    self?.memoryStats = MemoryStatsReader.snapshot()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // Process timer: 2s
        memoryProcessTimer = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await ProcessInspector.shared.snapshot()
                await MainActor.run {
                    guard let self else { return }
                    self.memoryProcesses = snapshot.entries
                    self.memoryTotalProcessCount = snapshot.totalCount
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // Pressure monitor
        if memoryPressureMonitor == nil {
            let monitor = PressureMonitor { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.memoryPressure = level
                }
            }
            monitor.start()
            memoryPressureMonitor = monitor
        }
    }

    func stopMemoryMonitoring() {
        // Don't actually stop — keep running in background
        // Users can navigate away and come back to live data
    }

    // MARK: - Helpers

    private static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}
