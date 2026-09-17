import SwiftUI
import Core
import AppKit

@MainActor
final class DeveloperJunkModel: ObservableObject {
    /// Shared so a scan survives the user switching tabs. The detail pane
    /// swaps views on selection, which destroys a @StateObject and everything
    /// it was holding — including a Space Lens walk that took minutes.
    static let shared = DeveloperJunkModel()

    @Published var artifacts: [DeveloperArtifact] = []
    @Published var selected: Set<URL> = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var hasScanned = false
    @Published var totalReclaimable: UInt64 = 0
    @Published var lastUndoToken: UndoToken?
    @Published var actionMessage: String?

    // Live progress
    @Published var scannedDirectories = 0
    @Published var foundCount = 0
    @Published var liveReclaimable: UInt64 = 0
    @Published var currentPath = ""

    /// Extra roots the user added on top of the auto-detected code folders.
    @Published var extraRoots: [URL] = []

    private let scanner = DeveloperScanner()
    private let deletion = DeletionService.shared
    private var scanTask: Task<Void, Never>?

    var defaultRoots: [URL] { DeveloperScanner.defaultRoots() }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        artifacts = []
        scannedDirectories = 0
        foundCount = 0
        liveReclaimable = 0
        currentPath = ""
        if lastUndoToken == nil { actionMessage = nil }

        let roots = (defaultRoots + extraRoots).isEmpty ? nil : (defaultRoots + extraRoots)
        scanTask = Task { [scanner] in
            let found = await scanner.scan(roots: roots) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.scannedDirectories = progress.scannedDirectories
                    self.foundCount = progress.foundCount
                    self.liveReclaimable = progress.reclaimableBytes
                    if !progress.currentPath.isEmpty {
                        self.currentPath = Self.tildify(progress.currentPath)
                    }
                }
            }
            await MainActor.run {
                self.artifacts = found
                // Default-check only confirmed, auto-safe wins.
                self.selected = Set(found.filter { $0.safety == .safe }.map(\.url))
                self.recomputeTotal()
                self.isScanning = false
                self.hasScanned = true
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        isScanning = false
    }

    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
        recomputeTotal()
    }

    func selectAll(safeOnly: Bool) {
        selected = Set(artifacts
            .filter { safeOnly ? $0.safety == .safe : true }
            .map(\.url))
        recomputeTotal()
    }

    func clearSelection() { selected = []; recomputeTotal() }

    private func recomputeTotal() {
        totalReclaimable = artifacts
            .filter { selected.contains($0.url) }
            .reduce(UInt64(0)) { $0 &+ $1.size }
    }

    func cleanSelected() {
        let urls = artifacts.filter { selected.contains($0.url) }.map(\.url)
        guard !urls.isEmpty else { return }
        isCleaning = true
        actionMessage = nil
        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: urls, source: .developerJunk)
                let token = result.token
                let skipped = result.failures.count
                await MainActor.run {
                    self.lastUndoToken = token
                    var msg = "Moved \(formattedDevSize(token.totalBytes)) to Trash"
                    if skipped > 0 {
                        msg += " — \(skipped) skipped (permission denied)"
                    }
                    self.actionMessage = msg
                    self.isCleaning = false
                }
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
                    self.actionMessage = "Restored \(formattedDevSize(token.totalBytes))"
                }
                self.scan()
            } catch {
                await MainActor.run { self.actionMessage = "Undo failed: \(error)" }
            }
        }
    }

    func dismissUndo() {
        guard let token = lastUndoToken else { return }
        Task { [deletion] in
            try? await deletion.empty(token)
            await MainActor.run {
                self.lastUndoToken = nil
                self.actionMessage = "Permanently removed \(formattedDevSize(token.totalBytes))"
            }
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan Folder"
        if panel.runModal() == .OK {
            for url in panel.urls where !extraRoots.contains(url) {
                extraRoots.append(url)
            }
            scan()
        }
    }

    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}

struct DeveloperJunkView: View {
    @ObservedObject private var model = DeveloperJunkModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if model.isScanning {
                    liveProgress
                } else if model.hasScanned && !model.artifacts.isEmpty {
                    summaryLine
                }

                if let msg = model.actionMessage {
                    undoBar(msg)
                }

                if !model.hasScanned && !model.isScanning {
                    emptyState
                } else if model.artifacts.isEmpty && !model.isScanning {
                    cleanState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(model.artifacts) { artifact in
                            DeveloperArtifactRow(
                                artifact: artifact,
                                isSelected: model.selected.contains(artifact.url),
                                onToggle: { model.toggle(artifact.url) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, hasSelectableResults ? 96 : 28)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom) {
            if hasSelectableResults { footer }
        }
    }

    private var hasSelectableResults: Bool {
        model.hasScanned && !model.artifacts.isEmpty
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Developer Junk")
                    .font(Theme.Text.title.weight(.bold))
                Text("Build output and dependency caches across your code folders — each one labelled with how to bring it back.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if model.isScanning {
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            } else {
                Button { model.addFolder() } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                Button(model.hasScanned ? "Rescan" : "Scan") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var liveProgress: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scanned \(model.scannedDirectories) folders · found \(model.foundCount) · \(formattedDevSize(model.liveReclaimable))")
                    .font(Theme.Text.metric)
                Text(model.currentPath)
                    .font(Theme.Text.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var summaryLine: some View {
        Text("\(model.artifacts.count) item\(model.artifacts.count == 1 ? "" : "s") · \(formattedDevSize(model.artifacts.reduce(0) { $0 &+ $1.size })) reclaimable")
            .font(Theme.Text.caption)
            .foregroundStyle(.secondary)
    }

    private func undoBar(_ msg: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            Text(msg).font(Theme.Text.caption.weight(.medium))
            Spacer()
            if model.lastUndoToken != nil {
                Button("Undo") { model.undoLast() }.buttonStyle(.bordered)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Done") { model.dismissUndo() }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ok.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ok.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Floating footer (clean action)

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Select safe") { model.selectAll(safeOnly: true) }
                .buttonStyle(.link)
            Button("Clear") { model.clearSelection() }
                .buttonStyle(.link)
            Spacer()
            Text("\(model.selected.count) selected")
                .font(Theme.Text.metric)
                .foregroundStyle(.secondary)
            Button {
                model.cleanSelected()
            } label: {
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Clean \(formattedDevSize(model.totalReclaimable))")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selected.isEmpty || model.isCleaning)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Empty / clean states

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer.fill")
                .font(Theme.Text.display)
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Scan your code folders for reclaimable build junk")
                .font(Theme.Text.control.weight(.semibold))
            Text("Looks for node_modules, .next, build/, target, .gradle, __pycache__ and more — at any depth under \(rootsLabel).")
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Scan now") { model.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var cleanState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(Theme.Text.display).foregroundStyle(Theme.ok)
            Text("No developer junk found")
                .font(Theme.Text.control.weight(.semibold))
            Text("Nothing reclaimable under \(rootsLabel).")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var rootsLabel: String {
        let roots = model.defaultRoots + model.extraRoots
        if roots.isEmpty { return "your home folder" }
        return roots.map { DeveloperJunkModel.tildify($0.path) }.joined(separator: ", ")
    }
}

// MARK: - Row

private struct DeveloperArtifactRow: View {
    let artifact: DeveloperArtifact
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 14) {
                checkbox
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(artifact.projectName)
                            .font(Theme.Text.control.weight(.semibold))
                        Text("·").foregroundStyle(.secondary)
                        Text(artifact.displayName)
                            .font(Theme.Text.body)
                            .foregroundStyle(.secondary)
                        safetyBadge
                    }
                    Text(artifact.reason)
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(Theme.Text.eyebrow)
                            .foregroundStyle(Theme.accent)
                        Text("Restore: \(artifact.restoreCommand)")
                            .font(Theme.Text.caption.monospaced())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(DeveloperJunkModel.tildify(artifact.url.path))
                        .font(Theme.Text.eyebrow.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(formattedDevSize(artifact.size))
                    .font(Theme.Text.metric)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentRing : (hovering ? Theme.border.opacity(2.0) : Theme.border),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }

    private var checkbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Theme.border, lineWidth: 1.5)
                )
                .frame(width: 18, height: 18)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(Theme.Text.eyebrow.weight(.heavy))
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 1)
    }

    @ViewBuilder
    private var safetyBadge: some View {
        switch artifact.safety {
        case .safe:              StatusChip(kind: .safe, text: "Safe")
        case .reviewRecommended: StatusChip(kind: .review, text: "Review")
        case .destructive:       StatusChip(kind: .destructive, text: "Caution")
        }
    }
}

func formattedDevSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
