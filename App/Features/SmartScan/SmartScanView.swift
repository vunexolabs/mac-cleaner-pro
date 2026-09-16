import SwiftUI
import Core

@MainActor
final class SmartScanModel: ObservableObject {
    @Published var results: [RuleScanResult] = []
    @Published var selected: Set<String> = []     // ruleIDs the user has checked
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var loadError: String?
    @Published var totalReclaimable: UInt64 = 0
    @Published var lastScannedAt: Date?
    @Published var lastUndoToken: UndoToken?
    @Published var actionMessage: String?
    @Published var scanDisplayActive = false

    // Live, real-time scan progress (driven by ScanEvent stream).
    @Published var liveBytesScanned: UInt64 = 0
    @Published var liveFilesScanned: Int = 0
    @Published var liveCurrentRule: String = ""
    @Published var liveRuleIndex: Int = 0
    @Published var liveRuleTotal: Int = 0
    @Published var liveStreamPaths: [String] = []

    private let engine = ScanEngine()
    private let deletion = DeletionService.shared
    private var scanTask: Task<Void, Never>?

    func scan() {
        scanTask?.cancel()
        guard let pack = loadBundledPack() else { return }
        isScanning = true
        scanDisplayActive = true
        results = []
        // Reset live counters for a fresh scan.
        liveBytesScanned = 0
        liveFilesScanned = 0
        liveCurrentRule = ""
        liveRuleIndex = 0
        liveRuleTotal = pack.rules.count
        liveStreamPaths = []
        if lastUndoToken == nil { actionMessage = nil }
        let start = Date()
        scanTask = Task { [engine] in
            let scanned = await engine.scan(pack: pack) { [weak self] event in
                // Hop to MainActor — emitter is called from the engine actor.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .ruleStarted(_, let name, let index, let total):
                        self.liveCurrentRule = name
                        self.liveRuleIndex = index
                        self.liveRuleTotal = total
                    case .fileSampled(let path, _):
                        // Display ~/-relative paths when possible for readability.
                        let display = Self.tildify(path)
                        withAnimation(.easeOut(duration: 0.28)) {
                            self.liveStreamPaths.append(display)
                            if self.liveStreamPaths.count > 20 {
                                self.liveStreamPaths.removeFirst()
                            }
                        }
                    case .progress(let bytes, let files):
                        self.liveBytesScanned = bytes
                        self.liveFilesScanned = files
                    case .ruleCompleted:
                        break
                    }
                }
            }
            // A cancelled scan returns whatever it had walked so far. Publishing
            // that would present a partial figure as a finished one — the user
            // hit Cancel and would still be shown a confident "reclaimable" total.
            if Task.isCancelled { return }

            await MainActor.run {
                self.results = scanned
                self.selected = Set(scanned.filter { $0.safety == .safe }.map(\.ruleID))
                self.recomputeTotal()
                self.lastScannedAt = Date()
                self.isScanning = false
            }
            // Show the completion burst for at least 0.7s after the real
            // scan finishes — feels more deliberate than snapping straight
            // to the results list.
            let elapsed = Date().timeIntervalSince(start)
            let minDisplay: Double = 1.6
            let remaining = max(0, minDisplay - elapsed)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            try? await Task.sleep(for: .milliseconds(700))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { self.scanDisplayActive = false }
            }
        }
    }

    private static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    func cancel() {
        scanTask?.cancel()
        isScanning = false
        scanDisplayActive = false
        liveStreamPaths = []
    }

    /// Move every URL from currently-selected, non-helper, non-empty rules to
    /// the staging trash. Surfaces an undo token until the user dismisses it
    /// or a new clean replaces it.
    func cleanSelected() {
        let urls = results
            .filter { selected.contains($0.ruleID) && !$0.requiresHelper && !$0.items.isEmpty }
            .flatMap { $0.items.map(\.url) }
        guard !urls.isEmpty else { return }
        isCleaning = true
        actionMessage = nil
        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: urls, source: .smartScan)
                let token = result.token
                let skipped = result.failures.count
                await MainActor.run {
                    self.lastUndoToken = token
                    var msg = "Moved \(formattedSize(token.totalBytes))"
                    if skipped > 0 {
                        msg += " — \(skipped) item\(skipped == 1 ? "" : "s") skipped (permission denied)"
                    }
                    self.actionMessage = msg
                    self.isCleaning = false
                }
                // Rescan so the cleaned rows zero out.
                self.scan()
            } catch {
                await MainActor.run {
                    self.actionMessage = "Clean failed: \(error)"
                    self.isCleaning = false
                }
            }
        }
    }

    func undoLast() {
        guard let token = lastUndoToken else { return }
        Task { [deletion] in
            do {
                try await deletion.undo(token)
                await MainActor.run {
                    self.lastUndoToken = nil
                    self.actionMessage = "Restored \(formattedSize(token.totalBytes))"
                }
                self.scan()
            } catch {
                await MainActor.run {
                    self.actionMessage = "Undo failed: \(error)"
                }
            }
        }
    }

    func dismissUndo() {
        guard let token = lastUndoToken else { return }
        Task { [deletion] in
            try? await deletion.empty(token)
            await MainActor.run {
                self.lastUndoToken = nil
                self.actionMessage = "Permanently removed \(formattedSize(token.totalBytes))"
            }
        }
    }

    func toggle(ruleID: String) {
        if selected.contains(ruleID) { selected.remove(ruleID) } else { selected.insert(ruleID) }
        recomputeTotal()
    }

    private func recomputeTotal() {
        totalReclaimable = results
            .filter { selected.contains($0.ruleID) }
            .reduce(UInt64(0)) { $0 &+ $1.totalSize }
    }

    private func loadBundledPack() -> RulePack? {
        do {
            return try RulePackLoader.loadBundled()
        } catch RulePackLoader.LoadError.bundledResourceMissing {
            loadError = "Bundled rule pack missing"
            return nil
        } catch {
            loadError = "Decode failed: \(error)"
            return nil
        }
    }
}

struct SmartScanView: View {
    @StateObject private var model = SmartScanModel()
    @StateObject private var gate = LicenseGate.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let err = model.loadError {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(Theme.bad)
                        .padding(12)
                        .glassCard(padded: false)
                }
                if model.scanDisplayActive {
                    scanningState
                } else if model.results.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
                if model.lastUndoToken != nil { undoBanner }
                else if let msg = model.actionMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            // Reserve space for the floating footer only when it's visible.
            .padding(.bottom, (!model.results.isEmpty || model.scanDisplayActive) ? 110 : 28)
            .animation(.easeOut(duration: 0.25), value: model.scanDisplayActive)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom) {
            // Footer is hidden on the initial empty state — nothing to clean,
            // nothing to report. It re-appears once results exist or a scan
            // is actively running.
            if !model.results.isEmpty || model.scanDisplayActive {
                footer
            }
        }
        .task { await gate.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(
                eyebrow: "One-click scan",
                title: "Smart Scan",
                subtitle: model.lastScannedAt
                    .map { "Last scanned \($0.formatted(date: .omitted, time: .standard))" }
                    ?? "Tap Scan to break down System Data — caches, logs, and reclaimable space"
            )
            Spacer()
            if model.isScanning {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(SoftButtonStyle())
            } else {
                Button {
                    model.scan()
                } label: {
                    Label(model.results.isEmpty ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
            }
        }
    }

    // MARK: - States

    private var scanningState: some View {
        ScanProgressCard(model: model)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 26) {
            // Compact header — small badge icon + title on the same row
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.accentRing, lineWidth: 1)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Scan")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.3)
                    Text("Break down what's hiding in System Data — safely.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // What gets scanned — 4 category tiles
            HStack(spacing: 10) {
                ScanCategoryTile(icon: "internaldrive",       title: "Caches",     subtitle: "User & system")
                ScanCategoryTile(icon: "doc.text",             title: "Logs",       subtitle: "Diagnostics")
                ScanCategoryTile(icon: "hammer",               title: "Developer",  subtitle: "Xcode artifacts")
                ScanCategoryTile(icon: "safari",               title: "Browsers",   subtitle: "Chrome · Safari")
            }

            // Primary CTA
            if model.isScanning {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                    Spacer()
                }
                .frame(height: 48)
            } else {
                Button {
                    model.scan()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                        Text("Start Smart Scan")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(GradientButtonStyle())
                .frame(height: 48)
            }

            // Trust line
            HStack(spacing: 18) {
                Spacer()
                trustItem(icon: "lock.shield",                   text: "Local-only scan")
                trustDot
                trustItem(icon: "arrow.uturn.backward.circle",   text: "30-day undo")
                trustDot
                trustItem(icon: "checkmark.seal",                text: "Trash-first")
                Spacer()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard(padded: false)
    }

    private func trustItem(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var trustDot: some View {
        Circle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 3, height: 3)
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(groupedByCategory(), id: \.0) { category, rules in
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        ForEach(rules) { result in
                            RuleRow(
                                result: result,
                                isSelected: model.selected.contains(result.ruleID),
                                onToggle: { model.toggle(ruleID: result.ruleID) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer (floating)

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                AnimatedByteCount(
                    value: Double(model.totalReclaimable),
                    font: .system(size: 26, weight: .semibold).monospacedDigit()
                )
                .animation(.easeInOut(duration: 0.5), value: model.totalReclaimable)
            }
            Spacer()
            Button {
                model.cleanSelected()
            } label: {
                HStack(spacing: 8) {
                    if model.isCleaning {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Cleaning…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Clean Selected")
                    }
                }
            }
            .buttonStyle(GradientButtonStyle(
                disabled: model.totalReclaimable == 0 || model.isCleaning || !gate.canCleanNow
            ))
            .disabled(model.totalReclaimable == 0 || model.isCleaning || !gate.canCleanNow)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    private var undoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.actionMessage ?? "Files staged in trash")
                    .font(.system(size: 13, weight: .medium))
                Text("Undo to restore, or dismiss to permanently delete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { model.undoLast() }
                .buttonStyle(SoftButtonStyle())
            Button("Dismiss") { model.dismissUndo() }
                .buttonStyle(SoftButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.ok.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.ok.opacity(0.34), lineWidth: 1)
        )
    }

    private func groupedByCategory() -> [(RulePack.Category, [RuleScanResult])] {
        let grouped = Dictionary(grouping: model.results, by: \.category)
        return RulePack.Category.allOrdered
            .compactMap { cat in grouped[cat].map { (cat, $0) } }
    }
}

// MARK: - Rule row (glass card with gradient checkbox)

private struct RuleRow: View {
    let result: RuleScanResult
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    private var disabled: Bool { result.requiresHelper || result.totalSize == 0 }

    var body: some View {
        Button(action: { if !disabled { onToggle() } }) {
            HStack(alignment: .center, spacing: 14) {
                // Custom gradient checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Theme.brandGradient)
                                         : AnyShapeStyle(Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.clear : Theme.border,
                                    lineWidth: 1.5
                                )
                        )
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .opacity(disabled ? 0.4 : 1.0)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(result.displayName)
                            .font(.system(size: 14, weight: .medium))
                        SafetyBadge(safety: result.safety)
                        if result.requiresHelper {
                            StatusChip(kind: .helper, text: "Requires helper")
                        }
                    }
                    if let err = result.error {
                        Text(err).font(.caption).foregroundStyle(Theme.bad)
                    } else if result.requiresHelper {
                        Text("Approve the privileged helper to scan this category")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if result.items.isEmpty {
                        Text("Nothing to clean")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(result.items.count) item\(result.items.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(formattedSize(result.totalSize))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(result.totalSize == 0 ? .secondary : .primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accentRing : (hovering ? Theme.border.opacity(2.0) : Theme.border),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(disabled ? 0.65 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

/// Small tile shown in the Smart Scan empty state — gives users a concrete
/// preview of what each scan category looks like before they tap Start.
private struct ScanCategoryTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

private struct SafetyBadge: View {
    let safety: RulePack.Safety
    var body: some View {
        switch safety {
        case .safe:               StatusChip(kind: .safe, text: "Safe")
        case .reviewRecommended:  StatusChip(kind: .review, text: "Review")
        case .destructive:        StatusChip(kind: .destructive, text: "Destructive")
        }
    }
}

private func formattedSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

extension RulePack.Category {
    static var allOrdered: [RulePack.Category] {
        [.caches, .logs, .developer, .browser, .mail, .trash, .uninstaller, .other]
    }
    var displayName: String {
        switch self {
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .developer: return "Developer"
        case .browser: return "Browsers"
        case .mail: return "Mail"
        case .trash: return "Trash"
        case .uninstaller: return "Uninstaller"
        case .other: return "Other"
        }
    }
}
