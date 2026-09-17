import SwiftUI
import AppKit
import Core

@MainActor
final class SpaceLensModel: ObservableObject {
    /// Shared so a scan survives the user switching tabs. The detail pane
    /// swaps views on selection, which destroys a @StateObject and everything
    /// it was holding — including a Space Lens walk that took minutes.
    static let shared = SpaceLensModel()

    @Published var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    @Published var tree: SpaceLensNode?
    @Published var path: [SpaceLensNode] = []      // breadcrumb stack from root → current focus
    @Published var isScanning = false
    @Published var bytesScanned: UInt64 = 0
    @Published var currentScanPath: String = ""
    @Published var selected: SpaceLensNode?
    @Published var hovering: SpaceLensNode?
    @Published var actionMessage: String?
    @Published var lastUndoToken: UndoToken?

    private let scanner = SpaceLensScanner()
    private let deletion = DeletionService.shared
    private var task: Task<Void, Never>?

    var current: SpaceLensNode? { path.last ?? tree }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url {
            root = url
            tree = nil
            path = []
            selected = nil
        }
    }

    func scan() {
        task?.cancel()
        isScanning = true
        bytesScanned = 0
        currentScanPath = ""
        selected = nil
        path = []
        let target = root
        task = Task { [scanner, weak self] in
            let result = await scanner.scan(root: target) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.bytesScanned = progress.bytesScanned
                    self.currentScanPath = Self.tildify(progress.currentPath)
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.tree = result
                self.isScanning = false
                self.bytesScanned = result.size
            }
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    /// Drill into a directory node (push onto the breadcrumb stack).
    func drill(into node: SpaceLensNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        path.append(node)
        selected = nil
    }

    /// Pop the breadcrumb to a specific level (root index = -1, first push = 0…).
    func navigate(toIndex index: Int) {
        if index < 0 {
            path.removeAll()
        } else if index < path.count {
            path = Array(path.prefix(index + 1))
        }
        selected = nil
    }

    func revealInFinder(_ node: SpaceLensNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func trashSelected() {
        guard let node = selected else { return }
        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: [node.url], source: .manual)
                await MainActor.run {
                    self.lastUndoToken = result.token
                    self.actionMessage = "Moved \(byteString(result.token.totalBytes)) to trash"
                    self.selected = nil
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

    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}

// MARK: - View

/// Which visualiser the chart panel shows. Both read the same tree and share
/// the same hover/selection bindings, so switching keeps your place.
enum SpaceLensChart: String, CaseIterable, Identifiable {
    case sunburst, treemap
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sunburst: return "Sunburst"
        case .treemap:  return "Treemap"
        }
    }
    var systemImage: String {
        switch self {
        case .sunburst: return "chart.pie"
        case .treemap:  return "square.grid.2x2"
        }
    }
}

struct SpaceLensView: View {
    @ObservedObject private var model = SpaceLensModel.shared
    @AppStorage("MCP-SpaceLens-Chart") private var chart: SpaceLensChart = .sunburst

    var body: some View {
        // The scroll container is load-bearing, not decoration. Without it this
        // page rendered above the title bar: the heading collided with the
        // window title and the sidebar's brand lockup was pushed off the top.
        // Every page that renders correctly has one; Space Lens was the only
        // one that did not. Removing maxHeight, the width-class dependency and
        // the unified toolbar style each failed to fix it; this is what did.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            controls
            if model.tree == nil && !model.isScanning {
                emptyState
            } else if model.isScanning && model.tree == nil {
                scanningState
            } else {
                chartSection
            }
            if model.lastUndoToken != nil { undoBanner }
            else if let msg = model.actionMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Header

    private var header: some View {
        SectionHeader(
            eyebrow: "Every byte, mapped",
            title: "Space Lens",
            subtitle: "See where your disk is going. Drill in, reclaim out."
        )
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Theme.brandGradient)
            Text(SpaceLensModel.tildify(model.root.path))
                .font(Theme.Text.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose Folder…") { model.chooseRoot() }
                .buttonStyle(SoftButtonStyle())
            if model.isScanning {
                Button("Cancel") { model.cancel() }
                    .buttonStyle(SoftButtonStyle())
            } else {
                Button {
                    model.scan()
                } label: {
                    Label(model.tree == nil ? "Scan" : "Rescan", systemImage: "rectangle.grid.3x2")
                }
                .buttonStyle(GradientButtonStyle())
            }
        }
        .padding(14)
        .glassCard(padded: false)
    }

    // MARK: States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.accentRing, lineWidth: 1)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "rectangle.grid.3x2")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Visualize every byte on your disk")
                        .font(Theme.Text.title)
                        .tracking(-0.3)
                    Text("A live treemap or sunburst of any folder — click to drill in, right-click to clean.")
                        .font(Theme.Text.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Three quick-start tiles
            HStack(spacing: 10) {
                QuickStartTile(icon: "house",       label: "Home",      subtitle: "~/", action: { model.root = URL(fileURLWithPath: NSHomeDirectory()); model.scan() })
                QuickStartTile(icon: "internaldrive", label: "System", subtitle: "/", action: { model.root = URL(fileURLWithPath: "/"); model.scan() })
                QuickStartTile(icon: "doc.text.image", label: "Documents", subtitle: "~/Documents", action: { model.root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents"); model.scan() })
                QuickStartTile(icon: "arrow.down.circle", label: "Downloads", subtitle: "~/Downloads", action: { model.root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads"); model.scan() })
            }
        }
        .padding(28)
        .glassCard(padded: false)
        .frame(maxWidth: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.10), lineWidth: 4)
                    .frame(width: 52, height: 52)
                ProgressView().controlSize(.regular).tint(Theme.accent)
            }
            VStack(spacing: 4) {
                Text("Mapping the filesystem…")
                    .font(Theme.Text.control.weight(.semibold))
                Text(byteString(model.bytesScanned))
                    .font(Theme.Text.metricLarge)
                    .foregroundStyle(Theme.brandGradient)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: model.bytesScanned)
                Text(model.currentScanPath.isEmpty ? "warming up…" : model.currentScanPath)
                    .font(Theme.Text.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(28)
        .glassCard(padded: false)
    }

    // MARK: Chart section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                breadcrumb
                Spacer(minLength: 12)
                chartPicker
            }
            HStack(alignment: .top, spacing: Layout.s3) {
                chartPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                rightSidebar
                    .frame(width: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var chartPicker: some View {
        Picker("Chart", selection: $chart) {
            ForEach(SpaceLensChart.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
        .help("Switch between the sunburst wheel and the treemap")
        .accessibilityLabel("Chart style")
    }

    private func ascend() {
        if !model.path.isEmpty {
            model.path.removeLast()
            model.selected = nil
        }
    }

    private var chartPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
            if let cur = model.current, !cur.children.isEmpty {
                Group {
                    switch chart {
                    case .sunburst:
                        SunburstView(
                            focus: cur,
                            canAscend: !model.path.isEmpty,
                            hovering: $model.hovering,
                            selected: $model.selected,
                            onSelect: { _ in /* binding already synced */ },
                            onDrill: { node in model.drill(into: node) },
                            onAscend: { ascend() }
                        )
                    case .treemap:
                        TreemapView(
                            focus: cur,
                            canAscend: !model.path.isEmpty,
                            hovering: $model.hovering,
                            selected: $model.selected,
                            onSelect: { _ in /* binding already synced */ },
                            onDrill: { node in model.drill(into: node) },
                            onAscend: { ascend() }
                        )
                    }
                }
                .id("\(chart.rawValue)-\(cur.id)")
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .padding(20)
            } else {
                Text("Empty folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 480)
    }

    /// Right-side sidebar: items list (hover-synced with sunburst) on top,
    /// selection details + actions on the bottom.
    private var rightSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            itemsList
            Divider().opacity(0.3)
            selectionDetail
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(padded: false)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var itemsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ITEMS")
                    .font(Theme.Text.eyebrow.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if let cur = model.current {
                    Text("\(cur.children.count)")
                        .font(Theme.Text.metric)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if let cur = model.current {
                        ForEach(Array(cur.children.enumerated()), id: \.element.id) { idx, child in
                            ChildListRow(
                                child: child,
                                hue: hueForChildIndex(idx, of: cur),
                                isSelected: model.selected?.id == child.id,
                                isHovering: model.hovering?.id == child.id,
                                onHoverChange: { hovering in
                                    if hovering {
                                        if model.hovering?.id != child.id { model.hovering = child }
                                    } else if model.hovering?.id == child.id {
                                        model.hovering = nil
                                    }
                                },
                                onTap: { model.selected = child },
                                onDrill: { model.drill(into: child) }
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private var selectionDetail: some View {
        let node = model.selected ?? model.hovering
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selected != nil ? "SELECTED" : "HOVER")
                    .font(Theme.Text.eyebrow.weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let n = node {
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.30), Theme.accent.opacity(0.05)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 12) {
                        Image(systemName: n.isDirectory ? "folder.fill" : "doc.fill")
                            .font(Theme.Text.title)
                            .foregroundStyle(Theme.brandGradient)
                            .padding(.leading, 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.name)
                                .font(Theme.Text.rowTitle.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(byteString(n.size))
                                .font(Theme.Text.metric)
                                .foregroundStyle(Theme.accent)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Text(SpaceLensModel.tildify(n.url.path))
                    .font(Theme.Text.eyebrow.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let cur = model.current, cur.size > 0 {
                    let pct = Double(n.size) / Double(cur.size) * 100
                    HStack(spacing: 6) {
                        Text(String(format: "%.1f%%", pct))
                            .font(Theme.Text.metric)
                            .foregroundStyle(Theme.accent)
                        Text("of \(cur.name)")
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if model.selected != nil {
                    HStack(spacing: 8) {
                        Button {
                            if let s = model.selected { model.revealInFinder(s) }
                        } label: {
                            Label("Reveal", systemImage: "magnifyingglass")
                                .font(Theme.Text.caption.weight(.medium))
                        }
                        .buttonStyle(SoftButtonStyle())
                        Button {
                            model.trashSelected()
                        } label: {
                            Label("Trash", systemImage: "trash")
                                .font(Theme.Text.caption.weight(.medium))
                        }
                        .buttonStyle(GradientButtonStyle())
                    }
                    if let n = model.selected, n.isDirectory && !n.children.isEmpty {
                        Button {
                            model.drill(into: n)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.right.square")
                                Text("Drill into \(n.name)")
                            }
                            .font(Theme.Text.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
            } else {
                Text("Hover or click a tile to inspect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// List dots, sunburst slices and treemap tiles all take their colour from
    /// the one definition in `SunburstLayout`.
    private func hueForChildIndex(_ idx: Int, of parent: SpaceLensNode) -> Double {
        SunburstLayout.topLevelHue(forChildAt: idx, of: parent)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            BreadcrumbCrumb(label: model.root.lastPathComponent.isEmpty ? "/" : model.root.lastPathComponent,
                            icon: "house.fill",
                            isLast: model.path.isEmpty,
                            action: { model.navigate(toIndex: -1) })
            ForEach(Array(model.path.enumerated()), id: \.offset) { idx, node in
                Image(systemName: "chevron.right")
                    .font(Theme.Text.eyebrow)
                    .foregroundStyle(.secondary.opacity(0.6))
                BreadcrumbCrumb(label: node.name,
                                icon: nil,
                                isLast: idx == model.path.count - 1,
                                action: { model.navigate(toIndex: idx) })
            }
            Spacer()
            if let cur = model.current {
                Text(byteString(cur.size))
                    .font(Theme.Text.metric)
                    .foregroundStyle(.secondary)
            }
        }
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

// MARK: - Items list row (sidebar)

/// Row in the right-sidebar items list. Hover state syncs with the sunburst's
/// hovering binding, so hovering here also lights up the corresponding ring.
private struct ChildListRow: View {
    let child: SpaceLensNode
    let hue: Double
    let isSelected: Bool
    let isHovering: Bool
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void
    let onDrill: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Color dot matching the sunburst hue
                Circle()
                    .fill(Color(hue: hue, saturation: 0.62, brightness: 0.95))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(child.name)
                        .font(Theme.Text.rowTitle.weight(isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(child.isDirectory
                         ? "\(child.children.count) item\(child.children.count == 1 ? "" : "s")"
                         : "file")
                        .font(Theme.Text.eyebrow)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Text(byteString(child.size))
                    .font(Theme.Text.metric)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                if child.isDirectory && !child.children.isEmpty {
                    Button(action: onDrill) {
                        Image(systemName: "chevron.right")
                            .font(Theme.Text.eyebrow)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1.0 : 0.4)
                    // Only visible on hover, so a pointer-free user would never
                    // find it; the row's custom action below covers that too.
                    .accessibilityLabel("Open \(child.name)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? Theme.accentSoft
                          : (isHovering ? Theme.hoverFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentRing : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { onHoverChange($0) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDrill() })
        // Read as one row, and expose drilling — which is otherwise a
        // double-click or a hover-only chevron — as a named action.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { onDrill() }
    }

    private var spokenLabel: String {
        let kind = child.isDirectory
            ? "folder, \(child.children.count) item\(child.children.count == 1 ? "" : "s")"
            : "file"
        return "\(child.name), \(kind), \(byteString(child.size))"
    }
}

// MARK: - Helpers

private struct BreadcrumbCrumb: View {
    let label: String
    let icon: String?
    let isLast: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(Theme.Text.eyebrow)
                }
                Text(label)
                    .font(Theme.Text.caption.weight(isLast ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && !isLast ? Theme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(isLast)
    }
}

private struct QuickStartTile: View {
    let icon: String
    let label: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(Theme.Text.control.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Theme.Text.rowTitle.weight(.semibold))
                    Text(subtitle)
                        .font(Theme.Text.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                    .strokeBorder(hovering ? Theme.accentRing : Theme.border, lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
