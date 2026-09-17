import SwiftUI
import AppKit
import Quartz
import Core

@MainActor
final class LargeFilesModel: ObservableObject {
    /// Shared so a scan survives the user switching tabs. The detail pane
    /// swaps views on selection, which destroys a @StateObject and everything
    /// it was holding — including a Space Lens walk that took minutes.
    static let shared = LargeFilesModel()

    @Published var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    @Published var minSizeMB: Double = 100
    @Published var olderThanDays: Int = 0       // 0 = no age filter
    @Published var entries: [FileEntry] = []
    @Published var selection: Set<URL> = []
    @Published var isScanning = false
    @Published var actionMessage: String?
    @Published var lastUndoToken: UndoToken?

    private let scanner = LargeFileScanner()
    private let deletion = DeletionService.shared
    private var task: Task<Void, Never>?

    func pickRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func scan() {
        task?.cancel()
        isScanning = true
        // Don't wipe the message while an Undo banner is still active.
        if lastUndoToken == nil { actionMessage = nil }
        let q = LargeFileQuery(
            root: root,
            minSize: UInt64(minSizeMB * 1024 * 1024),
            olderThanDays: olderThanDays > 0 ? olderThanDays : nil
        )
        task = Task { [scanner] in
            let result = await scanner.scan(q)
            await MainActor.run {
                self.entries = result
                self.selection.removeAll()
                self.isScanning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    func quickLookSelection() {
        guard !selection.isEmpty else { return }
        let urls = entries.filter { selection.contains($0.url) }.map(\.url)
        QuickLookCoordinator.shared.show(urls: urls)
    }

    func trashSelection() {
        let urls = entries.filter { selection.contains($0.url) }.map(\.url)
        guard !urls.isEmpty else { return }
        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: urls, source: .largeFiles)
                await MainActor.run {
                    self.lastUndoToken = result.token
                    var msg = "Moved \(byteString(result.token.totalBytes))"
                    if !result.failures.isEmpty {
                        msg += " — \(result.failures.count) skipped (permission denied)"
                    }
                    self.actionMessage = msg
                }
                self.scan()
            } catch {
                await MainActor.run { self.actionMessage = "Trash failed: \(error)" }
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
                    self.actionMessage = "Restored \(byteString(token.totalBytes))"
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
                self.actionMessage = nil
            }
        }
    }

    var totalSelectedBytes: UInt64 {
        entries.filter { selection.contains($0.url) }
               .reduce(UInt64(0)) { $0 &+ $1.size }
    }
}

struct LargeFilesView: View {
    @ObservedObject private var model = LargeFilesModel.shared
    @StateObject private var gate = LicenseGate.shared
    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        .init(\.size, order: .reverse)
    ]

    private var hasResults: Bool { !model.entries.isEmpty }
    private var showFooter: Bool { hasResults || model.isScanning }

    var body: some View {
        // Scroll container for the same reason as Space Lens and Duplicate
        // Finder — without it the page creeps into the title bar. The effect is
        // milder here (about 15pt) but it is the same fault.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                eyebrow: "Find what's heavy",
                title: "Large & Old Files",
                subtitle: "Walk any folder by size and age. Quick Look any match."
            )
            controls
            table
            if model.lastUndoToken != nil { undoBanner }
            if showFooter { footer }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await gate.refresh() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.brandGradient)
                Text(model.root.path)
                    .font(Theme.Text.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { model.pickRoot() }
                    .buttonStyle(SoftButtonStyle())
            }

            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    Text("Min size")
                        .font(Theme.Text.caption.weight(.semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    // No `step:`. macOS renders tick marks for a stepped
                    // slider, and 199 of them merged into a dashed line under
                    // the track. Rounding in the binding keeps the 10 MB
                    // granularity without drawing them.
                    Slider(
                        value: Binding(
                            get: { model.minSizeMB },
                            set: { model.minSizeMB = ($0 / 10).rounded() * 10 }
                        ),
                        in: 10...2000
                    )
                        .tint(Theme.accent)
                        .frame(width: 180)
                    Text("\(Int(model.minSizeMB)) MB")
                        .font(Theme.Text.metric)
                        .frame(width: 60, alignment: .trailing)
                }
                Divider().frame(height: 18)
                HStack(spacing: 8) {
                    Text("Older than")
                        .font(Theme.Text.caption.weight(.semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.olderThanDays) {
                        Text("Any").tag(0)
                        Text("30 days").tag(30)
                        Text("180 days").tag(180)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Spacer()
                if model.isScanning {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(SoftButtonStyle())
                } else {
                    Button {
                        model.scan()
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .padding(16)
        .glassCard(padded: false)
    }

    private var table: some View {
        Table(sortedEntries, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name") { entry in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable().frame(width: 16, height: 16)
                    Text(entry.url.lastPathComponent).lineLimit(1)
                }
            }
            .width(min: 200, ideal: 280)

            TableColumn("Size", value: \.size) { entry in
                Text(byteString(entry.size)).font(.body.monospacedDigit())
            }
            .width(80)

            TableColumn("Modified", value: \.modifiedSortKey) { entry in
                Text(entry.modifiedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    .font(.callout)
            }
            .width(110)

            TableColumn("Type") { entry in
                Text(entry.fileExtension.isEmpty ? "folder" : entry.fileExtension)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Path") { entry in
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        // A definite minimum, because maxHeight: .infinity alone collapses to
        // nothing inside a ScrollView — and the empty state is an overlay on
        // this table, so it then centred on a zero-height box and landed on top
        // of the controls card above it.
        .frame(minHeight: 380, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .overlay {
            if model.isScanning && model.entries.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(Theme.accent.opacity(0.10), lineWidth: 4)
                            .frame(width: 48, height: 48)
                        ProgressView().controlSize(.regular).tint(Theme.accent)
                    }
                    VStack(spacing: 3) {
                        Text("Walking the filesystem…")
                            .font(Theme.Text.control.weight(.semibold))
                        Text("Streaming files larger than \(Int(model.minSizeMB)) MB")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            } else if !model.isScanning && model.entries.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accentSoft)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.accentRing, lineWidth: 1)
                            )
                            .frame(width: 52, height: 52)
                        Image(systemName: "magnifyingglass")
                            .font(Theme.Text.title)
                            .foregroundStyle(Theme.accent)
                    }
                    VStack(spacing: 4) {
                        Text("Find your biggest, oldest files")
                            .font(Theme.Text.control.weight(.semibold))
                        Text("Pick a folder, set a minimum size, and click Scan.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            }
        }
    }

    private var sortedEntries: [FileEntry] {
        model.entries.sorted(using: sortOrder)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.entries.count) files found · selected")
                    .font(Theme.Text.caption.weight(.semibold))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                AnimatedByteCount(
                    value: Double(model.totalSelectedBytes),
                    font: Theme.Text.metricLarge
                )
                .animation(.easeInOut(duration: 0.4), value: model.totalSelectedBytes)
            }
            Spacer()
            Button {
                model.quickLookSelection()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .buttonStyle(SoftButtonStyle())
            // Space bar previews the selection, same as in Finder.
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.selection.isEmpty)

            Button {
                model.trashSelection()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(GradientButtonStyle(
                disabled: model.selection.isEmpty || !gate.canCleanNow
            ))
            .disabled(model.selection.isEmpty || !gate.canCleanNow)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(14)
        .glassCard(padded: false)
    }

    private var undoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(Theme.Text.sectionTitle)
                .foregroundStyle(Theme.ok)
            Text(model.actionMessage ?? "Files staged in trash")
                .font(Theme.Text.rowTitle)
            Spacer()
            Button("Undo") { model.undoLast() }
                .keyboardShortcut("z", modifiers: .command)
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
}

private extension FileEntry {
    /// `Date?` doesn't conform to `Comparable`. Map missing dates to distant past
    /// so they sort to the bottom under the default ascending order.
    var modifiedSortKey: Date { modifiedAt ?? .distantPast }
}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// MARK: - Quick Look

/// Bridges the AppKit `QLPreviewPanel` singleton — the only Quick Look API that
/// can present an inline panel on macOS — to a Swifty array-of-URLs datasource.
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private var urls: [URL] = []

    func show(urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
