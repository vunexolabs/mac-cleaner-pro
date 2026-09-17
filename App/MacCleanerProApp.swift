import SwiftUI
import AppKit
import Core

@main
struct MacCleanerProApp: App {
    @State private var showOnboarding = !OnboardingState.hasCompleted
    @StateObject private var theme = ThemeManager.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                // 980x640 meant the window could not be made small enough to
                // sit beside anything else on a 13" display. The layouts now
                // reflow, so the floor is what the content genuinely needs.
                .frame(minWidth: 720, minHeight: 560)
                .task {
                    // Re-hydrate undo tokens written by previous launches, then
                    // drop anything past the retention window. Without the load,
                    // staged files from an earlier session are stranded in the
                    // Trash with no way to restore them from the app.
                    // The stored preference has to reach Core before the
                    // first clean, not just when Settings happens to be opened.
                    let permanent = UserDefaults.standard.bool(forKey: "MacCleanerPro.permanentDelete")
                    await DeletionService.shared.setMode(permanent ? .permanent : .trash)
                    await DeletionService.shared.loadPersistedTokens()
                    await DeletionService.shared.sweepExpiredTokens()
                }
                .environmentObject(theme)
                .preferredColorScheme(theme.appearance.colorScheme)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView { showOnboarding = false }
                        .environmentObject(theme)
                        .preferredColorScheme(theme.appearance.colorScheme)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Mac Cleaner Pro Help") {
                    if let url = URL(string: "https://maccleanerpro.com/help") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("View Source on GitHub") {
                    if let url = URL(string: "https://github.com/vunexolabs/mac-cleaner-pro") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/vunexolabs/mac-cleaner-pro/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandGroup(after: .appInfo) {
                Divider()
                // Sponsor accounts aren't set up yet — point supporters at
                // email rather than a GitHub Sponsors page that 404s. Keep in
                // step with SettingsView.openSupportEmail().
                Button("Support Mac Cleaner Pro…") {
                    if let url = URL(string: "mailto:hello@maccleanerpro.com?subject=Supporting%20Mac%20Cleaner%20Pro") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            // Theme submenu under View, so Cmd+, → System Settings still works
            // and people who like keyboard nav can flip themes from the menu bar.
            CommandGroup(after: .toolbar) {
                Menu("Theme") {
                    ForEach(Appearance.allCases) { mode in
                        Button {
                            theme.appearance = mode
                        } label: {
                            HStack {
                                Image(systemName: mode.systemImage)
                                Text(mode.label)
                                if theme.appearance == mode {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(theme)
                .preferredColorScheme(theme.appearance.colorScheme)
        }
    }
}
