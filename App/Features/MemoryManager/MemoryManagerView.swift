import SwiftUI
import AppKit
import Core
import Combine

// MARK: - View Model

@MainActor
final class MemoryManagerModel: ObservableObject {

    // Reference to session manager for persistent data
    private let session = SessionManager.shared

    // Local UI state
    @Published var selectedPIDs: Set<pid_t> = []
    @Published var isFreeing = false
    @Published var lastResult: FreeResult?
    @Published var actionMessage: String?

    // Settings
    @AppStorage("MCP-MemoryManager-AutoMode") var autoMode = false

    private var lastAutoFire: Date = .distantPast
    private var autoPressureObserver: AnyCancellable?

    // Forward session data as computed properties
    var stats: MemoryStats { session.memoryStats }
    var pressure: MemoryPressureLevel { session.memoryPressure }
    var processes: [ProcessMemoryEntry] { session.memoryProcesses }
    var totalProcessCount: Int { session.memoryTotalProcessCount }

    init() {
        // Watch pressure changes for auto-mode
        autoPressureObserver = session.$memoryPressure.sink { [weak self] level in
            self?.maybeAutoFire(level: level)
        }
    }

    func start() {
        // Start persistent monitoring (runs even when view is dismissed)
        session.startMemoryMonitoring()

        // Clean up stale selections
        let live = Set(session.memoryProcesses.map(\.id))
        selectedPIDs.formIntersection(live)
    }

    func stop() {
        // Don't actually stop — session keeps running
        // Just clean up local state if needed
    }

    // MARK: Pressure

    private func maybeAutoFire(level: MemoryPressureLevel) {
        guard autoMode, level == .critical else { return }
        guard Date().timeIntervalSince(lastAutoFire) > 120 else { return }
        lastAutoFire = Date()
        Task { await self.runQuickFree(auto: true) }
    }

    // MARK: Actions

    func runQuickFree(auto: Bool = false) async {
        guard !isFreeing else { return }
        isFreeing = true
        actionMessage = auto
            ? "Auto: pressure critical — running Quick Free"
            : "Applying memory pressure so the kernel drops cached pages…"
        let result = await MemoryFreer.shared.quickFree()
        await onFreeFinished(result, label: auto ? "Auto Quick Free" : "Quick Free")
    }

    /// What the confirmation sheet is asking about. Quitting apps can destroy
    /// unsaved work, so it never happens on a single click.
    struct PendingQuit: Identifiable {
        let id = UUID()
        let pids: [pid_t]
        let names: [String]

        var title: String {
            pids.count == 1 ? "Quit \(names.first ?? "this app")?" : "Quit \(pids.count) apps?"
        }

        /// Up to three names, then "and N more" — enough to recognise a mistake
        /// without an unbounded wall of text.
        var summary: String {
            let shown = names.prefix(3).joined(separator: ", ")
            let extra = names.count - min(names.count, 3)
            let list = extra > 0 ? "\(shown) and \(extra) more" : shown
            return "Mac Cleaner Pro will ask \(list) to quit. "
                + "Anything with unsaved changes will prompt you to save first."
        }
    }

    @Published var pendingQuit: PendingQuit?

    /// Stage a confirmation instead of quitting immediately.
    func requestQuitSelected() {
        guard !isFreeing else { return }
        let selected = processes.filter { selectedPIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        pendingQuit = PendingQuit(pids: selected.map(\.id), names: selected.map(\.name))
    }

    func confirmPendingQuit(force: Bool) {
        guard let pending = pendingQuit else { return }
        pendingQuit = nil
        Task { await quitSelected(pids: pending.pids, force: force) }
    }

    func quitSelected(pids: [pid_t], force: Bool = false) async {
        guard !isFreeing else { return }
        guard !pids.isEmpty else { return }
        isFreeing = true
        let plural = pids.count == 1 ? "" : "s"
        // "Asking" rather than "Quitting": a graceful quit can be refused by an
        // app that puts up a save prompt, and claiming otherwise would be a lie
        // the very next frame.
        actionMessage = force
            ? "Force-quitting \(pids.count) app\(plural) and reclaiming…"
            : "Asking \(pids.count) app\(plural) to quit, then reclaiming…"
        let result = await MemoryFreer.shared.quitAndFree(pids: pids, force: force)
        selectedPIDs.removeAll()
        await onFreeFinished(result, label: force ? "Force Quit + Free" : "Quit + Free")
    }

    private func onFreeFinished(_ result: FreeResult, label: String) async {
        let entry = ActivityEntry(
            kind: .freed,
            source: .memoryManager,
            bytes: result.reclaimedBytes,
            itemCount: result.processesTerminated,
            note: "\(label) · \(result.strategy)"
        )
        await ActivityLog.shared.append(entry)
        self.lastResult = result
        self.isFreeing = false
        // Stats will update automatically from session
        self.actionMessage = format(result: result, label: label)
    }

    private func format(result: FreeResult, label: String) -> String {
        // A deliberate skip is the most useful thing we can say — report it
        // instead of a cheerful total the user didn't get.
        if let skipped = result.skippedReason {
            if result.processesTerminated > 0 {
                let n = result.processesTerminated
                return "\(label): \(n) app\(n == 1 ? "" : "s") asked to quit. \(skipped)"
            }
            return "\(label): \(skipped)"
        }

        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        var parts: [String] = []
        if result.processesTerminated > 0 {
            let n = result.processesTerminated
            parts.append("\(n) app\(n == 1 ? "" : "s") asked to quit")
        }
        if result.reclaimedBytes > 0 {
            parts.append("\(f.string(fromByteCount: Int64(result.reclaimedBytes))) freed")
        }
        if result.compressedDelta < 0 {
            let bytes = UInt64(-result.compressedDelta)
            parts.append("−\(f.string(fromByteCount: Int64(bytes))) decompressed")
        }
        if result.swapDelta < 0 {
            let bytes = UInt64(-result.swapDelta)
            parts.append("−\(f.string(fromByteCount: Int64(bytes))) swap")
        }
        if parts.isEmpty {
            // No delta means the kernel had nothing worth evicting. Saying so is
            // better than inventing an accomplishment — the previous copy
            // claimed "purgeable memory cleared" by a routine that never ran.
            return "\(label): nothing worth reclaiming — your memory is already in good shape"
        }
        return "\(label): " + parts.joined(separator: " · ")
    }
}

// MARK: - Main view

struct MemoryManagerView: View {
    @StateObject private var model = MemoryManagerModel()
    @StateObject private var session = SessionManager.shared
    @StateObject private var gate = LicenseGate.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                gaugeCard
                actionsCard
                processesCard
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.start() }
        .task { await gate.refresh() }
        // Note: No onDisappear — session keeps running in background!
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(
                eyebrow: "MEMORY",
                title: "Free up RAM",
                subtitle: "Live system memory, top consumers, one-click reclaim — based on the same kernel APIs Activity Monitor uses."
            )
            Spacer()
            PressureBadge(level: model.pressure)
        }
    }

    // MARK: Gauge

    private var gaugeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(usedTotalText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            MemoryStackedBar(stats: model.stats)
                .frame(height: 22)

            HStack(spacing: 18) {
                LegendDot(color: Theme.accent2, label: "App", value: bytes(model.stats.appBytes))
                LegendDot(color: Theme.bad,     label: "Wired", value: bytes(model.stats.wiredBytes))
                LegendDot(color: Theme.warn,    label: "Compressed", value: bytes(model.stats.compressedBytes))
                LegendDot(color: Theme.ok,      label: "Cached", value: bytes(model.stats.cachedBytes))
                LegendDot(color: .secondary,    label: "Free", value: bytes(model.stats.freeBytes))
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))

            if model.stats.swapTotalBytes > 0 || model.stats.swapUsedBytes > 0 {
                let swapFrac = model.stats.totalBytes > 0 ? Double(model.stats.swapUsedBytes) / Double(model.stats.totalBytes) : 0
                let isHigh = swapFrac > 0.25
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11))
                        .foregroundStyle(isHigh ? Theme.warn : .secondary)
                    Text("Swap: \(bytes(model.stats.swapUsedBytes)) used")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHigh ? Theme.warn : .secondary)
                    if isHigh {
                        Text("(emergency mode active)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.warn)
                    }
                }
            }
        }
        .glassCard()
    }

    private var usedTotalText: String {
        "\(bytes(model.stats.usedBytes)) of \(bytes(model.stats.totalBytes)) used"
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.runQuickFree() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.sparkles")
                        Text("Quick Free")
                    }
                }
                .buttonStyle(GradientButtonStyle(disabled: model.isFreeing || !gate.canCleanNow))
                .disabled(model.isFreeing || !gate.canCleanNow)

                Button {
                    model.requestQuitSelected()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("Quit Selected (\(model.selectedPIDs.count))")
                    }
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(model.isFreeing || model.selectedPIDs.isEmpty || !gate.canCleanNow)
                .confirmationDialog(
                    model.pendingQuit?.title ?? "",
                    isPresented: Binding(
                        get: { model.pendingQuit != nil },
                        set: { if !$0 { model.pendingQuit = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: model.pendingQuit
                ) { pending in
                    Button("Quit App\(pending.pids.count == 1 ? "" : "s")") {
                        model.confirmPendingQuit(force: false)
                    }
                    Button("Force Quit — unsaved work is lost", role: .destructive) {
                        model.confirmPendingQuit(force: true)
                    }
                    Button("Cancel", role: .cancel) { model.pendingQuit = nil }
                } message: { pending in
                    Text(pending.summary)
                }

                Spacer()

                Toggle(isOn: $model.autoMode) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.badge.automatic")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Auto-free on critical pressure")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!gate.canCleanNow)
            }

            if let msg = model.actionMessage {
                HStack(spacing: 8) {
                    if model.isFreeing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                    }
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .glassCard()
        .animation(.easeOut(duration: 0.2), value: model.actionMessage)
    }

    // MARK: Processes

    private var processesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top memory consumers")
                    .font(.system(size: 14, weight: .semibold))
                Text("(updates every 2s)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(processCountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // Header row
            HStack(spacing: 0) {
                Text("").frame(width: 28)
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("Memory").frame(width: 110, alignment: .trailing)
                Text("% RAM").frame(width: 70, alignment: .trailing)
                Text("").frame(width: 60)
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)

            Divider().opacity(0.3)

            LazyVStack(spacing: 0) {
                ForEach(model.processes.prefix(50)) { entry in
                    ProcessRow(
                        entry: entry,
                        totalRAM: model.stats.totalBytes,
                        selected: model.selectedPIDs.contains(entry.id),
                        onToggle: {
                            if model.selectedPIDs.contains(entry.id) {
                                model.selectedPIDs.remove(entry.id)
                            } else if entry.isOwnedByCurrentUser {
                                model.selectedPIDs.insert(entry.id)
                            }
                        }
                    )
                    Divider().opacity(0.15)
                }
            }
        }
        .glassCard()
    }

    private var processCountLabel: String {
        let shown = min(model.processes.count, 50)
        let total = max(model.totalProcessCount, model.processes.count)
        if total > shown {
            return "Top \(shown) of \(total)"
        }
        return "\(total) process\(total == 1 ? "" : "es")"
    }

    // MARK: helpers

    private func bytes(_ value: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: Int64(value))
    }
}

// MARK: - Stacked bar

private struct MemoryStackedBar: View {
    let stats: MemoryStats

    /// Spoken form of the breakdown the bar draws — without it the bar is a
    /// row of anonymous coloured rectangles with no label, value or text.
    private var spokenBreakdown: String {
        func b(_ v: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
        }
        return "\(b(stats.usedBytes)) of \(b(stats.totalBytes)) used. "
            + "App \(b(stats.appBytes)), wired \(b(stats.wiredBytes)), "
            + "compressed \(b(stats.compressedBytes)), cached \(b(stats.cachedBytes)), "
            + "free \(b(stats.freeBytes))."
    }

    var body: some View {
        GeometryReader { geo in
            let total = max(1, Double(stats.totalBytes))
            let segments: [(Double, Color)] = [
                (Double(stats.appBytes)        / total, Theme.accent2),
                (Double(stats.wiredBytes)      / total, Theme.bad),
                (Double(stats.compressedBytes) / total, Theme.warn),
                (Double(stats.cachedBytes)     / total, Theme.ok),
            ]
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: max(0, geo.size.width * seg.0))
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.4), value: stats.usedBytes)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory usage")
        .accessibilityValue(spokenBreakdown)
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let value: String
    /// Combined so VoiceOver reads "App, 5.2 GB" rather than stopping on the
    /// colour swatch, the word, and the number as three separate elements.
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pressure badge

private struct PressureBadge: View {
    let level: MemoryPressureLevel

    var body: some View {
        let kind: StatusChip.Kind = {
            switch level {
            case .normal:   return .safe
            case .warning:  return .review
            case .critical: return .destructive
            }
        }()
        return HStack(spacing: 6) {
            Text("Pressure")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            StatusChip(kind: kind, text: level.label)
        }
    }
}

// MARK: - Process row

private struct ProcessRow: View {
    let entry: ProcessMemoryEntry
    let totalRAM: UInt64
    let selected: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if entry.isOwnedByCurrentUser {
                    Toggle(isOn: Binding(get: { selected }, set: { _ in onToggle() })) { EmptyView() }
                        .toggleStyle(.checkbox)
                } else {
                    Image(systemName: "lock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("System-owned process — cannot quit from here.")
                }
            }
            .frame(width: 28)

            HStack(spacing: 8) {
                AppIconView(path: entry.executablePath)
                    .frame(width: 18, height: 18)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(entry.residentBytes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 110, alignment: .trailing)

            Text(percentText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            Text("PID \(entry.pid)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Theme.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 1) {
            if entry.isOwnedByCurrentUser { onToggle() }
        }
    }

    private func formatBytes(_ value: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        return f.string(fromByteCount: Int64(value))
    }

    private var percentText: String {
        guard totalRAM > 0 else { return "—" }
        let pct = Double(entry.residentBytes) / Double(totalRAM) * 100.0
        if pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }
}

private struct AppIconView: View {
    let path: String
    var body: some View {
        if let icon = Self.icon(for: path) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private static func icon(for path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        // Helper executables nest like:
        //   /Applications/Brave.app/Contents/Frameworks/
        //     Brave Helper.app/Contents/MacOS/Brave Helper
        // The *innermost* .app is a helper bundle with a generic icon — what
        // users actually recognize is the *outermost* .app ancestor. Walk up
        // collecting every .app component, then pick the topmost one.
        let components = (path as NSString).pathComponents
        var lastAppIndex: Int?
        for (i, c) in components.enumerated() where c.hasSuffix(".app") {
            // First .app encountered while walking from root is the outermost.
            if lastAppIndex == nil { lastAppIndex = i }
        }
        if let idx = lastAppIndex {
            let appPath = NSString.path(withComponents: Array(components.prefix(idx + 1)))
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
