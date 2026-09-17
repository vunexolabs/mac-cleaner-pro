import SwiftUI
import AppKit
import Core

/// Live permission status, shown once in onboarding and again in Settings.
///
/// Re-checks whenever the app comes forward, so returning from System Settings
/// updates the row without the user hunting for a "re-check" button — though
/// one is still offered, because the FDA probe is a heuristic and can lag.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [Permission: PermissionStatus] = [:]
    /// Set once we observe FDA flip to granted inside this session. The running
    /// process keeps its old sandbox until relaunch, so the app must restart
    /// before the grant means anything.
    @Published private(set) var relaunchRequired = false

    /// True when everything detectable is granted. Reads the published
    /// snapshot — `PermissionsCenter.allClear` probes the filesystem, which has
    /// no business running inside a view body.
    var allClear: Bool {
        !statuses.values.contains(.denied)
    }

    private var grantedAtLaunch: Set<Permission> = []

    init() {
        refresh(initial: true)
    }

    /// Re-probe permissions off the main thread, and publish only on change.
    ///
    /// Both halves matter. `PermissionsCenter.status` hits the filesystem —
    /// Full Disk Access is detected by trying to list a protected directory —
    /// and doing that on the main thread blocks the UI. Worse, this assigned a
    /// freshly-built dictionary every call, so `@Published` fired even when
    /// nothing had changed; inside the onboarding sheet's presentation
    /// animation that produced a new graph transaction on every pass and the
    /// sheet's nested runloop never settled, pinning a core at 100%.
    func refresh(initial: Bool = false) {
        Task { [weak self] in
            let next: [Permission: PermissionStatus] = await Task.detached(priority: .utility) {
                var probed: [Permission: PermissionStatus] = [:]
                for permission in Permission.allCases {
                    probed[permission] = PermissionsCenter.status(of: permission)
                }
                return probed
            }.value

            guard let self else { return }
            if initial {
                self.grantedAtLaunch = Set(next.filter { $0.value == .granted }.keys)
            } else {
                for (permission, status) in next
                where status == .granted
                    && permission.needsRelaunchAfterGranting
                    && !self.grantedAtLaunch.contains(permission) {
                    if !self.relaunchRequired { self.relaunchRequired = true }
                }
            }
            // Only publish a real change.
            if next != self.statuses { self.statuses = next }
        }
    }

    func open(_ permission: Permission) {
        switch permission {
        case .fullDiskAccess: FullDiskAccess.openSystemSettings()
        case .automation:     break   // macOS asks on first use; nothing to open.
        }
    }

    /// Relaunch so a new Full Disk Access grant actually applies.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

struct PermissionsCenterView: View {
    @ObservedObject var model: PermissionsModel
    /// Onboarding shows the full explanation; Settings shows the compact list.
    var showsIntro: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.s3) {
            if showsIntro {
                Text("macOS keeps these behind your explicit permission, and there's no way "
                     + "for an app to grant them for you. Here's everything Mac Cleaner Pro "
                     + "will ever ask for, and what each one is for — we won't ask again.")
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Layout.proseMax, alignment: .leading)
            }

            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    status: model.statuses[permission] ?? .decidedOnFirstUse,
                    onOpen: { model.open(permission) }
                )
            }

            if model.relaunchRequired {
                relaunchNotice
            }

            HStack {
                Button("Re-check") { model.refresh() }
                    .buttonStyle(SoftButtonStyle())
                Spacer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var relaunchNotice: some View {
        HStack(spacing: Layout.s3) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Theme.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.s1) {
                Text("Restart to finish").font(Theme.Text.rowTitle)
                Text("macOS applies Full Disk Access when an app starts, so Mac Cleaner Pro "
                     + "needs to relaunch before it can see the newly permitted files.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Layout.s2)
            Button("Relaunch") { model.relaunch() }
                .buttonStyle(GradientButtonStyle())
        }
        .padding(Layout.s3)
        .glassCard(padded: false)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Layout.s3) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Layout.s1) {
                HStack(spacing: Layout.s2) {
                    Text(permission.title).font(Theme.Text.rowTitle)
                    StatusChip(kind: chipKind, text: chipText)
                }
                Text(permission.rationale)
                    .font(Theme.Text.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .denied {
                    Text(permission.costOfDenial)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Layout.s2)

            if permission.requiresSystemSettings && status != .granted {
                Button("Open Settings", action: onOpen)
                    .buttonStyle(SoftButtonStyle())
                    .accessibilityLabel("Open System Settings for \(permission.title)")
            }
        }
        .padding(.vertical, Layout.s2)
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch status {
        case .granted:           return "checkmark.circle.fill"
        case .denied:            return "exclamationmark.triangle.fill"
        case .decidedOnFirstUse: return "questionmark.circle.fill"
        }
    }
    private var tint: Color {
        switch status {
        case .granted:           return Theme.ok
        case .denied:            return Theme.warn
        case .decidedOnFirstUse: return .secondary
        }
    }
    private var chipKind: StatusChip.Kind {
        switch status {
        case .granted:           return .safe
        case .denied:            return .review
        case .decidedOnFirstUse: return .info
        }
    }
    private var chipText: String {
        switch status {
        case .granted:           return "Granted"
        case .denied:            return "Not granted"
        case .decidedOnFirstUse: return "Asked when first used"
        }
    }
}
