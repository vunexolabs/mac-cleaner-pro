import SwiftUI
import AppKit
import Core

@MainActor
final class UninstallerModel: ObservableObject {
    /// Shared so a scan survives switching tabs — the detail pane swaps views
    /// on selection, which destroys a @StateObject and everything it holds.
    static let shared = UninstallerModel()

    @Published var apps: [AppRecord] = []
    @Published var selectedApp: AppRecord?
    @Published var leftovers: [Leftover] = []
    @Published var checkedLeftovers: Set<URL> = []
    @Published var includeBundle = true
    @Published var isLoadingApps = false
    @Published var isLoadingLeftovers = false
    @Published var actionMessage: String?
    @Published var lastUndoToken: UndoToken?

    private let discovery = AppDiscovery()
    private let finder = LeftoverFinder()
    private let deletion = DeletionService.shared

    func loadApps() {
        isLoadingApps = true
        Task { [discovery] in
            let list = await discovery.listInstalledApps()
            await MainActor.run {
                self.apps = list
                self.isLoadingApps = false
            }
        }
    }

    func select(_ app: AppRecord?) {
        selectedApp = app
        leftovers = []
        checkedLeftovers = []
        guard let app else { return }
        isLoadingLeftovers = true
        Task { [finder] in
            let found = await finder.leftovers(forBundleID: app.bundleID, appName: app.name)
            await MainActor.run {
                self.leftovers = found.sorted { $0.size > $1.size }
                // Default-check user-space leftovers (helper-required ones stay off in $0 mode).
                self.checkedLeftovers = Set(found
                    .filter { !$0.requiresHelper }
                    .map(\.url))
                self.isLoadingLeftovers = false
            }
        }
    }

    func toggle(leftover: Leftover) {
        if leftover.requiresHelper { return }   // gated until Developer ID is in place
        if checkedLeftovers.contains(leftover.url) {
            checkedLeftovers.remove(leftover.url)
        } else {
            checkedLeftovers.insert(leftover.url)
        }
    }

    var totalSelectedBytes: UInt64 {
        var total: UInt64 = 0
        if includeBundle, let app = selectedApp { total &+= app.size }
        for l in leftovers where checkedLeftovers.contains(l.url) {
            total &+= l.size
        }
        return total
    }

    func uninstall() {
        guard let app = selectedApp else { return }
        var urls: [URL] = []
        if includeBundle { urls.append(app.bundleURL) }
        urls.append(contentsOf: leftovers
            .filter { checkedLeftovers.contains($0.url) && !$0.requiresHelper }
            .map(\.url))
        guard !urls.isEmpty else { return }

        Task { [deletion] in
            do {
                let result = try await deletion.trashWithFailures(urls: urls, source: .uninstaller)
                await MainActor.run {
                    self.lastUndoToken = result.token
                    var msg = "Uninstalled \(app.name) — moved \(byteString(result.token.totalBytes))"
                    if !result.failures.isEmpty {
                        msg += " (\(result.failures.count) skipped)"
                    }
                    self.actionMessage = msg
                }
                self.loadApps()
                await MainActor.run { self.selectedApp = nil; self.leftovers = [] }
            } catch {
                await MainActor.run { self.actionMessage = "Uninstall failed: \(error)" }
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
                self.loadApps()
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
}

struct UninstallerView: View {
    @ObservedObject private var model = UninstallerModel.shared
    @StateObject private var gate = LicenseGate.shared

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 280, idealWidth: 320)
            detail
                .frame(minWidth: 380)
        }
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Installed Apps")
                        .font(Theme.Text.control.weight(.semibold))
                    Text("\(model.apps.count) found · sorted by size")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.loadApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Text.caption.weight(.semibold))
                }
                .buttonStyle(SoftButtonStyle())
                .keyboardShortcut("r", modifiers: .command)
                .help("Rescan installed apps")
                .accessibilityLabel("Rescan installed apps")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.3)
            if model.isLoadingApps && model.apps.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Looking for apps…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.apps, selection: Binding(
                    get: { model.selectedApp?.id },
                    set: { newID in
                        model.select(model.apps.first(where: { $0.id == newID }))
                    }
                )) { app in
                    AppRow(app: app, isSelected: model.selectedApp?.id == app.id)
                        .tag(app.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let app = model.selectedApp {
                detailHeader(app: app)
                if model.isLoadingLeftovers {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(Theme.accent)
                        Text("Hunting for leftovers…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    leftoversList
                }
                if model.lastUndoToken != nil { undoBanner }
                footer(app: app)
            } else {
                emptyDetail
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Compact header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.accentRing, lineWidth: 1)
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "shippingbox")
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Uninstaller")
                        .font(Theme.Text.title)
                        .tracking(-0.3)
                    Text("Remove apps and every file they leave behind.")
                        .font(Theme.Text.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Where leftovers live — info row
            HStack(spacing: 10) {
                LeftoverLocationTile(icon: "folder",          label: "Application Support")
                LeftoverLocationTile(icon: "clock",           label: "Caches & Logs")
                LeftoverLocationTile(icon: "gearshape",       label: "Preferences")
                LeftoverLocationTile(icon: "shippingbox",     label: "Containers")
            }

            // Hint card
            HStack(spacing: 12) {
                Image(systemName: "arrow.left")
                    .font(Theme.Text.control.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick any app to begin")
                        .font(Theme.Text.rowTitle.weight(.semibold))
                    Text("We scan 12 user-space locations for leftover files.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accentRing.opacity(0.6), lineWidth: 1)
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func detailHeader(app: AppRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable()
                .frame(width: 56, height: 56)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(Theme.Text.title)
                    .tracking(-0.4)
                Text(app.bundleID)
                    .font(Theme.Text.mono)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let v = app.version {
                        Label("v\(v)", systemImage: "tag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Label(byteString(app.size), systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var leftoversList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Toggle("Include the application bundle itself",
                       isOn: $model.includeBundle)
                    .padding(.bottom, 8)

                if model.leftovers.isEmpty {
                    Text("No leftovers found.").foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                ForEach(grouped(), id: \.0) { category, items in
                    Section {
                        ForEach(items) { leftover in
                            LeftoverRow(
                                leftover: leftover,
                                isChecked: model.checkedLeftovers.contains(leftover.url),
                                onToggle: { model.toggle(leftover: leftover) }
                            )
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(category.displayName).font(.subheadline.weight(.semibold))
                            if category.requiresHelper {
                                Text("Requires helper")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func grouped() -> [(LeftoverCategory, [Leftover])] {
        let dict = Dictionary(grouping: model.leftovers, by: \.category)
        return LeftoverCategory.allCases
            .compactMap { c in dict[c].map { (c, $0) } }
    }

    private func footer(app: AppRecord) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Will reclaim")
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
                model.uninstall()
            } label: {
                Label("Uninstall \(app.name)", systemImage: "trash")
            }
            .buttonStyle(GradientButtonStyle(
                disabled: model.totalSelectedBytes == 0 || !gate.canCleanNow
            ))
            .disabled(model.totalSelectedBytes == 0 || !gate.canCleanNow)
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
            Text(model.actionMessage ?? "Uninstalled — staged in trash")
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

/// Small tile shown in the empty detail pane to preview where leftovers
/// typically hide.
private struct LeftoverLocationTile: View {
    let icon: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(Theme.Text.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(label)
                .font(Theme.Text.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

private struct AppRow: View {
    let app: AppRecord
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(Theme.Text.rowTitle)
                    .lineLimit(1)
                Text(byteString(app.size))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accentRing : Color.clear, lineWidth: 1)
        )
    }
}

private struct LeftoverRow: View {
    let leftover: Leftover
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: { if !leftover.requiresHelper { onToggle() } }) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isChecked ? AnyShapeStyle(Theme.brandGradient)
                                        : AnyShapeStyle(Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    isChecked ? Color.clear : Theme.border,
                                    lineWidth: 1.5
                                )
                        )
                        .frame(width: 16, height: 16)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(Theme.Text.eyebrow.weight(.heavy))
                            .foregroundStyle(.white)
                    }
                }
                .opacity(leftover.requiresHelper ? 0.4 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(leftover.url.lastPathComponent)
                        .font(Theme.Text.rowTitle)
                        .lineLimit(1)
                    Text(leftover.url.deletingLastPathComponent().path)
                        .font(Theme.Text.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(byteString(leftover.size))
                    .font(Theme.Text.metric)
                    .foregroundStyle(leftover.requiresHelper ? .secondary : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.04) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(leftover.requiresHelper ? 0.65 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
