import SwiftUI
import AppKit
import Core

// MARK: - Model

@MainActor
final class DuplicateFinderModel: ObservableObject {
    /// Shared so a scan survives the user switching tabs. The detail pane
    /// swaps views on selection, which destroys a @StateObject and everything
    /// it was holding — including a Space Lens walk that took minutes.
    static let shared = DuplicateFinderModel()

    @Published var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    @Published var minSizeMB: Double = 1
    @Published var groups: [DuplicateGroup] = []
    @Published var selected: Set<URL> = []          // files queued for deletion
    @Published var isScanning = false
    @Published var actionMessage: String?
    @Published var lastUndoToken: UndoToken?

    private let scanner = DuplicateScanner()
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
        if lastUndoToken == nil { actionMessage = nil }
        let minBytes = UInt64(minSizeMB * 1_048_576)
        let root = self.root
        task = Task { [scanner] in
            let result = await scanner.scan(root: root, minSize: minBytes)
            await MainActor.run {
                self.groups = result
                self.applySmartSelect()
                self.isScanning = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    /// For each group, pre-select every file except the newest (index 0).
    func applySmartSelect() {
        selected = Set(groups.flatMap { $0.files.dropFirst().map(\.url) })
    }

    func toggle(url: URL, in group: DuplicateGroup) {
        let groupURLs = Set(group.files.map(\.url))
        let currentlySelected = selected.intersection(groupURLs)
        if selected.contains(url) {
            // Prevent deselecting if it's the only selected file in the group
            // (would leave nothing to delete — allow, user may be doing custom selection)
            selected.remove(url)
        } else {
            // Prevent selecting all files — must keep at least one
            if currentlySelected.count >= group.files.count - 1 { return }
            selected.insert(url)
        }
    }

    func trashSelected() {
        let urls = Array(selected)
        guard !urls.isEmpty else { return }
        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: urls, source: .duplicateFinder)
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
            await MainActor.run { self.lastUndoToken = nil; self.actionMessage = nil }
        }
    }

    var totalWastedBytes: UInt64 { groups.reduce(0) { $0 &+ $1.wastedBytes } }
    var totalSelectedBytes: UInt64 {
        let allFiles = Dictionary(uniqueKeysWithValues: groups.flatMap { $0.files }.map { ($0.url, $0.size) })
        return selected.reduce(0) { $0 &+ (allFiles[$1] ?? 0) }
    }
}

// MARK: - Root view

struct DuplicateFinderView: View {
    @ObservedObject private var model = DuplicateFinderModel.shared
    @StateObject private var gate = LicenseGate.shared

    var body: some View {
        // Same fix as Space Lens: without a scroll container this page renders
        // above the title bar, colliding with the window title and pushing the
        // sidebar's brand lockup off the top.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                eyebrow: "Reclaim wasted space",
                title: "Duplicate Finder",
                subtitle: "Finds files with identical content — not just the same name."
            )
            controls
            resultsArea
            if model.lastUndoToken != nil { undoBanner }
            if !model.groups.isEmpty { footer }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await gate.refresh() }
    }

    // MARK: Controls

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
                    // Same tick-mark problem as Large Files, worse here:
                    // 0.1 steps over 0.1...500 is ~5000 ticks.
                    Slider(
                        value: Binding(
                            get: { model.minSizeMB },
                            set: { model.minSizeMB = ($0 * 10).rounded() / 10 }
                        ),
                        in: 0.1...500
                    )
                        .tint(Theme.accent)
                        .frame(width: 180)
                    Text(model.minSizeMB < 1
                         ? "\(Int(model.minSizeMB * 1024)) KB"
                         : "\(Int(model.minSizeMB)) MB")
                        .font(Theme.Text.metric)
                        .frame(width: 60, alignment: .trailing)
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

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )

            if model.isScanning {
                scanningOverlay
            } else if model.groups.isEmpty {
                emptyOverlay
            } else {
                groupsList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var scanningOverlay: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.10), lineWidth: 4)
                    .frame(width: 48, height: 48)
                ProgressView().controlSize(.regular).tint(Theme.accent)
            }
            VStack(spacing: 3) {
                Text("Scanning for duplicates…")
                    .font(Theme.Text.control.weight(.semibold))
                Text("Hashing files larger than \(model.minSizeMB < 1 ? "\(Int(model.minSizeMB * 1024)) KB" : "\(Int(model.minSizeMB)) MB")")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private var emptyOverlay: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accentRing, lineWidth: 1)
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "doc.on.doc")
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 4) {
                Text("Find identical files")
                    .font(Theme.Text.control.weight(.semibold))
                Text("Pick a folder and click Scan. Only files with matching content are flagged.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .padding(28)
    }

    private var groupsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.groups) { group in
                    GroupCard(
                        group: group,
                        selected: $model.selected,
                        onToggle: { model.toggle(url: $0, in: group) }
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.groups.count) duplicate \(model.groups.count == 1 ? "group" : "groups") · selected")
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
            Button("Smart Select") { model.applySmartSelect() }
                .buttonStyle(SoftButtonStyle())
                .help("Keep the newest copy of each duplicate, select the rest")
            Button {
                model.trashSelected()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(GradientButtonStyle(
                disabled: model.selected.isEmpty || !gate.canCleanNow
            ))
            .disabled(model.selected.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(14)
        .glassCard(padded: false)
    }

    // MARK: Undo banner

    private var undoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(Theme.Text.sectionTitle)
                .foregroundStyle(Theme.ok)
            Text(model.actionMessage ?? "Files staged in trash")
                .font(Theme.Text.rowTitle)
            Spacer()
            Button("Undo") { model.undoLast() }.buttonStyle(SoftButtonStyle())
                .keyboardShortcut("z", modifiers: .command)
            Button("Dismiss") { model.dismissUndo() }.buttonStyle(SoftButtonStyle())
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

// MARK: - Group card

private struct GroupCard: View {
    let group: DuplicateGroup
    @Binding var selected: Set<URL>
    let onToggle: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc.fill")
                    .font(Theme.Text.rowTitle.weight(.semibold))
                    .foregroundStyle(Theme.brandGradient)
                Text(group.files[0].url.lastPathComponent)
                    .font(Theme.Text.rowTitle.weight(.semibold))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(group.files.count) copies")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(byteString(group.wastedBytes)) recoverable")
                    .font(Theme.Text.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accentSoft.opacity(0.4))

            Divider().opacity(0.2)

            ForEach(Array(group.files.enumerated()), id: \.element.id) { idx, file in
                FileRow(
                    file: file,
                    isSelected: selected.contains(file.url),
                    isLast: idx == group.files.count - 1,
                    onToggle: { onToggle(file.url) }
                )
                if idx < group.files.count - 1 {
                    Divider().opacity(0.12).padding(.leading, 44)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - File row

private struct FileRow: View {
    let file: DuplicateFile
    let isSelected: Bool
    let isLast: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.border, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(Theme.Text.eyebrow.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                // File icon
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().frame(width: 20, height: 20)

                // Name + path
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent)
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)
                    Text(file.url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.Text.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Modified date
                if let date = file.modifiedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.Text.metric)
                        .foregroundStyle(.secondary)
                }

                // Keep badge (unselected = kept)
                if !isSelected {
                    Text("KEEP")
                        .font(Theme.Text.eyebrow.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.ok)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Theme.ok.opacity(0.12))
                        )
                        .overlay(Capsule().strokeBorder(Theme.ok.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Theme.hoverFill : Color.clear)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

// MARK: - Helpers

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
