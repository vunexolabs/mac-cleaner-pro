import SwiftUI
import AppKit
import Core

@MainActor
final class SettingsModel: ObservableObject {
    @Published var licenseKey: String = ""
    @Published var licenseState: LicenseManager.State = .free
    @Published var gracePeriodDaysLeft: Int? = nil
    @Published var isActivating = false
    /// Inline result message shown under the key field after an Activate attempt.
    @Published var activationMessage: String?
    /// `true` when `activationMessage` describes a failure (render it red).
    @Published var activationFailed = false

    init() { refresh() }

    func refresh() {
        Task {
            let state = await LicenseManager.shared.currentState()
            let graceDays: Int?
            if case .pro = state {
                graceDays = await SecureLicenseStorage.shared.gracePeriodDaysRemaining()
            } else {
                graceDays = nil
            }
            await MainActor.run {
                self.licenseState = state
                self.gracePeriodDaysLeft = graceDays
                if case .pro(let key) = state { self.licenseKey = key }
            }
            await LicenseGate.shared.refresh()
        }
    }

    /// Validate the key the user typed and unlock Pro if it checks out.
    /// Offline Ed25519 verification is authoritative; the result is reported
    /// inline so no extra dialog is needed.
    func activateLicenseKey() {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isActivating = true
        activationMessage = nil
        Task {
            let state = await LicenseManager.shared.setLicenseKey(key)
            await MainActor.run {
                self.isActivating = false
                self.licenseState = state
                if case .pro = state {
                    self.activationFailed = false
                    self.activationMessage = "License activated — Pro features unlocked."
                } else {
                    self.activationFailed = true
                    self.activationMessage = "Not a valid license key."
                }
            }
            await LicenseGate.shared.refresh()
        }
    }

    func clearLicense() {
        Task {
            let state = await LicenseManager.shared.clearLicense()
            await MainActor.run {
                self.licenseState = state
                self.licenseKey = ""
                self.activationMessage = nil
                self.activationFailed = false
            }
            await LicenseGate.shared.refresh()
        }
    }

    func resetOnboarding() {
        OnboardingState.reset()
    }

    func revealActivityLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MacCleanerPro")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @StateObject private var permissions = PermissionsModel()
    /// Persisted here, applied to DeletionService on change and at launch.
    @AppStorage("MacCleanerPro.permanentDelete") private var permanentDelete = false
    @State private var confirmPermanent = false
    @StateObject private var model = SettingsModel()
    @EnvironmentObject private var theme: ThemeManager
    @State private var showingDevices = false

    private var isFree: Bool {
        switch model.licenseState {
        case .free: return true
        case .pro:  return false
        }
    }

    private var currentLicenseKey: String? {
        if case .pro(let key) = model.licenseState {
            return key
        }
        return nil
    }

    // Sponsor accounts (GitHub Sponsors, Open Collective, Ko-fi) aren't set
    // up yet — point supporters at email in the meantime instead of linking
    // to accounts that don't exist.
    private func openSupportEmail() {
        if let url = URL(string: "mailto:hello@maccleanerpro.com?subject=Supporting%20Mac%20Cleaner%20Pro") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeader(
                    eyebrow: "Preferences",
                    title: "Settings",
                    subtitle: "Personalize how Mac Cleaner Pro looks, behaves, and reports."
                )

                appearanceCard
                licenseCard
                permissionsCard
                privacyCard
                advancedCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Cards

    private var appearanceCard: some View {
        SettingsCard(icon: "paintbrush.pointed.fill",
                     title: "Appearance",
                     subtitle: "Pick a theme. Default is light, matching the website.") {
            HStack(spacing: 8) {
                ForEach(Appearance.allCases) { mode in
                    AppearanceTile(
                        mode: mode,
                        isSelected: theme.appearance == mode,
                        action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                theme.appearance = mode
                            }
                        }
                    )
                }
            }
        }
    }

    private var licenseCard: some View {
        SettingsCard(icon: "heart.fill",
                     title: "Support the project",
                     subtitle: "Free and open source. No licence, no subscription, no ads.") {
            VStack(alignment: .leading, spacing: Layout.s3) {
                Text("Mac Cleaner Pro is maintained by one person. Support goes to the Apple "
                     + "Developer Program fee that unlocks notarization and system-level "
                     + "cleanup, hosting for downloads, and the time to keep the rule packs "
                     + "current.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only destinations that actually exist — these mirror
                // .github/FUNDING.yml, which is the GitHub Sponsor button.
                HStack(spacing: Layout.s2) {
                    Button {
                        open("https://buymeacoffee.com/vunexolabs")
                    } label: {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(GradientButtonStyle())

                    Button {
                        open("https://ko-fi.com/vunexolabs")
                    } label: {
                        Label("Ko-fi", systemImage: "heart.fill")
                    }
                    .buttonStyle(SoftButtonStyle())

                    Spacer()
                }

                Button { openSupportEmail() } label: {
                    Label("Or just say hello", systemImage: "envelope")
                }
                .buttonStyle(.link)
                .font(Theme.Text.caption)

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Layout.s2) {
                        Text("Only needed if you bought a licence before the app became free. "
                             + "Everything is unlocked either way.")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LicenseStateBadge(state: model.licenseState,
                                          graceDaysLeft: model.gracePeriodDaysLeft)
                        TextField("MCP-XXXXXXXXXXXX", text: $model.licenseKey)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Text.mono)
                        HStack(spacing: Layout.s2) {
                            Button("Activate") { model.activateLicenseKey() }
                                .buttonStyle(SoftButtonStyle())
                                .disabled(model.licenseKey.isEmpty || model.isActivating)
                            if let msg = model.activationMessage {
                                Text(msg)
                                    .font(Theme.Text.caption)
                                    .foregroundStyle(model.activationFailed ? Theme.bad : Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.top, Layout.s2)
                } label: {
                    Text("Legacy licence key")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var deletionModeRow: some View {
        VStack(alignment: .leading, spacing: Layout.s2) {
            ToggleRow(
                label: "Delete permanently instead of using the Trash",
                sub: permanentDelete
                    ? "Cleaned files are removed immediately. Undo will not be available."
                    : "Cleaned files stage in the Trash so you can undo. Recommended.",
                isOn: Binding(
                    get: { permanentDelete },
                    set: { wantsPermanent in
                        // Turning it off is always safe and takes effect at once.
                        // Turning it on removes the undo this app is built
                        // around, so it asks first.
                        if wantsPermanent {
                            confirmPermanent = true
                        } else {
                            permanentDelete = false
                            applyDeletionMode()
                        }
                    }
                )
            )
            if permanentDelete {
                Label("Undo, the Activity Log's restore button and the 30-day window "
                      + "do nothing while this is on.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Delete files permanently?", isPresented: $confirmPermanent) {
            Button("Cancel", role: .cancel) { }
            Button("Delete permanently", role: .destructive) {
                permanentDelete = true
                applyDeletionMode()
            }
        } message: {
            Text("Cleaned files will be removed immediately instead of staged in the Trash. "
                 + "Nothing can be undone or restored — including from the Activity Log. "
                 + "Everything else about what gets selected stays the same.")
        }
        .onAppear { applyDeletionMode() }
    }

    private func applyDeletionMode() {
        let mode: DeletionMode = permanentDelete ? .permanent : .trash
        Task { await DeletionService.shared.setMode(mode) }
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private var permissionsCard: some View {
        SettingsCard(icon: "lock.shield.fill",
                     title: "Permissions",
                     subtitle: "What macOS has granted, and what it hasn't.") {
            PermissionsCenterView(model: permissions, showsIntro: false)
        }
    }

    private var privacyCard: some View {
        SettingsCard(icon: "hand.raised.fill",
                     title: "Privacy",
                     subtitle: "Nothing to configure, because there is nothing collecting.") {
            VStack(alignment: .leading, spacing: Layout.s2) {
                // This card used to offer toggles for telemetry, crash reports
                // and automatic updates. None of the three were wired to
                // anything: there is no analytics SDK, no crash reporter and no
                // updater in this app. A switch that does nothing is worse than
                // no switch, so they are gone and the guarantee is stated plainly.
                PrivacyFact(icon: "antenna.radiowaves.left.and.right.slash",
                            text: "No analytics, no telemetry, no crash reporting. A fresh install makes no network calls at all.")
                PrivacyFact(icon: "externaldrive.badge.xmark",
                            text: "Nothing is uploaded. Scan results, file paths and the activity log stay on this Mac.")
                PrivacyFact(icon: "doc.text.magnifyingglass",
                            text: "The source is public, so none of the above has to be taken on trust.")

                Button {
                    if let url = URL(string: "https://github.com/vunexolabs/mac-cleaner-pro") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Read the source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(SoftButtonStyle())
                .padding(.top, Layout.s1)
            }
        }
    }

    private var advancedCard: some View {
        SettingsCard(icon: "wrench.and.screwdriver.fill",
                     title: "Advanced",
                     subtitle: "Power-user controls.") {
            VStack(spacing: Layout.s3) {
                deletionModeRow
                Divider().opacity(0.3)
                AdvancedActionRow(
                    icon: "folder",
                    title: "Reveal Activity Log folder",
                    subtitle: "~/Library/Application Support/MacCleanerPro",
                    action: { model.revealActivityLog() }
                )
                AdvancedActionRow(
                    icon: "sparkles",
                    title: "Show onboarding on next launch",
                    subtitle: "Re-runs the welcome wizard next time you open the app.",
                    action: { model.resetOnboarding() }
                )
            }
        }
    }
}

// MARK: - Reusable bits

private struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(Theme.Text.sectionTitle)
                        .foregroundStyle(Theme.brandGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Text.sectionTitle)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            content
        }
        .padding(20)
        .glassCard(padded: false)
    }
}

private struct AppearanceTile: View {
    let mode: Appearance
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(preview)
                        .frame(height: 64)
                    Image(systemName: mode.systemImage)
                        .font(Theme.Text.sectionTitle)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.brandGradient)
                                                    : AnyShapeStyle(Color.secondary))
                }
                Text(mode.label)
                    .font(Theme.Text.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft
                                     : (hovering ? Theme.hoverFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentRing : Theme.border,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var preview: AnyShapeStyle {
        switch mode {
        case .light: return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF1F3F9)],
            startPoint: .top, endPoint: .bottom))
        case .dark: return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: 0x0E1016), Color(hex: 0x1A1E28)],
            startPoint: .top, endPoint: .bottom))
        case .system: return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: 0xFFFFFF), Color(hex: 0x1A1E28)],
            startPoint: .leading, endPoint: .trailing))
        }
    }
}

private struct ToggleRow: View {
    let label: String
    let sub: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Text.rowTitle)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 4)
    }
}

private struct AdvancedActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(Theme.Text.control.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Text.rowTitle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.Text.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
                    .fill(hovering ? Theme.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct LicenseStateBadge: View {
    let state: LicenseManager.State
    var graceDaysLeft: Int? = nil  // non-nil → Pro but offline/grace period

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(badgeColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: badgeIcon)
                    .font(Theme.Text.control.weight(.semibold))
                    .foregroundStyle(badgeColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(badgeText)
                    .font(Theme.Text.rowTitle.weight(.semibold))
                Text(badgeSub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(badgeColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(badgeColor.opacity(0.30), lineWidth: 1)
        )
    }

    private var isOffline: Bool { graceDaysLeft != nil }

    // Mac Cleaner Pro is free and open source — `.free` means "no legacy
    // license on file." Only `.pro` (a legacy pre-open-source purchase)
    // gets distinct treatment, as a thank-you badge rather than a feature gate.
    private var badgeColor: Color {
        switch state {
        case .free: return Theme.ok
        case .pro:  return isOffline ? Theme.warn : Theme.ok
        }
    }

    private var badgeIcon: String {
        switch state {
        case .free: return "checkmark.seal.fill"
        case .pro:  return isOffline ? "wifi.slash" : "heart.fill"
        }
    }

    private var badgeText: String {
        switch state {
        case .free: return "Free & open source"
        case .pro:  return isOffline ? "Supporter · offline mode" : "Supporter"
        }
    }

    private var badgeSub: String {
        switch state {
        case .free:
            return "No license required — every feature is unlocked."
        case .pro(let key):
            if let days = graceDaysLeft {
                let plural = days == 1 ? "day" : "days"
                return "Connect to the internet to revalidate · \(days) \(plural) remaining"
            }
            return redact(key)
        }
    }

    private func redact(_ key: String) -> String {
        guard key.count > 8 else { return key }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}


/// A single stated guarantee in the Privacy card. Not a control — there is
/// nothing to turn off.
private struct PrivacyFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Layout.s2) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Theme.ok)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
