import SwiftUI
import Core

/// Inline banner shown by a feature whose results are incomplete because a
/// permission is missing.
///
/// The point is to never again show a smaller number with no explanation. A
/// scan that can't see browser caches should say so, not quietly report less
/// than a clean would free.
struct PermissionNotice: View {
    let permission: Permission
    /// Named in the user's terms — "Smart Scan", not "ScanEngine".
    let feature: String

    @State private var status: PermissionStatus = .decidedOnFirstUse

    var body: some View {
        Group {
            if status == .denied {
                HStack(alignment: .top, spacing: Layout.s3) {
                    Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                        .foregroundStyle(Theme.warn)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Layout.s1) {
                        Text("\(feature) is only seeing part of your disk")
                            .font(Theme.Text.rowTitle)
                        Text(permission.costOfDenial)
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Layout.s2)

                    Button("Grant \(permission.title)") {
                        FullDiskAccess.openSystemSettings()
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                .padding(Layout.s3)
                .glassCard(padded: false)
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// Same shape as PermissionsModel.refresh: the probe touches the
    /// filesystem, so it runs off the main thread, and the result is assigned
    /// only when it differs.
    private func refresh() {
        let permission = self.permission
        Task {
            let next = await Task.detached(priority: .utility) {
                PermissionsCenter.status(of: permission)
            }.value
            if next != status { status = next }
        }
    }
}
