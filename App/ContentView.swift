import SwiftUI
import Core

private enum SidebarItem: String, CaseIterable, Hashable, Identifiable {
    case smartScan, spaceLens, memoryManager, largeFiles, developerJunk, duplicateFinder, uninstaller, activityLog, settings
    #if DEBUG
    case helperSmokeTest
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan:        return "Smart Scan"
        case .spaceLens:        return "Space Lens"
        case .memoryManager:    return "Memory"
        case .largeFiles:       return "Large & Old Files"
        case .developerJunk:    return "Developer Junk"
        case .duplicateFinder:  return "Duplicate Finder"
        case .uninstaller:      return "App Uninstaller"
        case .activityLog:      return "Activity Log"
        case .settings:         return "Settings"
        #if DEBUG
        case .helperSmokeTest:  return "Helper Smoke Test"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .smartScan:        return "sparkles"
        case .spaceLens:        return "rectangle.grid.3x2"
        case .memoryManager:    return "memorychip"
        case .largeFiles:       return "doc.text.magnifyingglass"
        case .developerJunk:    return "hammer"
        case .duplicateFinder:  return "doc.on.doc"
        case .uninstaller:      return "trash.square"
        case .activityLog:      return "clock.arrow.circlepath"
        case .settings:         return "gearshape"
        #if DEBUG
        case .helperSmokeTest:  return "stethoscope"
        #endif
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .smartScan
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            ZStack {
                BackgroundOrbs()
                detailContent
            }
            .toolbar {
                ToolbarItem(placement: .principal) { toolbarTitle }
                ToolbarItem(placement: .primaryAction) { ThemeToggle() }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch selection ?? .smartScan {
        case .smartScan:        SmartScanView()
        case .spaceLens:        SpaceLensView()
        case .memoryManager:    MemoryManagerView()
        case .largeFiles:       LargeFilesView()
        case .developerJunk:    DeveloperJunkView()
        case .duplicateFinder:  DuplicateFinderView()
        case .uninstaller:      UninstallerView()
        case .activityLog:      ActivityLogView()
        case .settings:         SettingsView()
        #if DEBUG
        case .helperSmokeTest:  HelperSmokeTestView()
        #endif
        }
    }

    private var toolbarTitle: some View {
        Text(selection?.title ?? "Mac Cleaner Pro")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup
            HStack(spacing: 10) {
                LogoMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Cleaner Pro")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                    Text("v1.0 · indie")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .opacity(0.3)
                .padding(.horizontal, 8)

            // Items
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarItem.allCases.filter { $0 != .settings }) { item in
                    SidebarRow(
                        item: item,
                        isSelected: selection == item,
                        onTap: { selection = item }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            Spacer()

            // Settings sits at the bottom, like Linear / Vercel.
            Divider().opacity(0.3).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(
                    item: .settings,
                    isSelected: selection == .settings,
                    onTap: { selection = .settings }
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Status pill
            HStack(spacing: 8) {
                PulsingDot(color: Theme.ok, size: 6)
                Text("All systems operational")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
        }
        .background(
            ZStack {
                // Subtle gradient tint behind the sidebar — gives it depth in
                // both light and dark mode without overpowering the content.
                LinearGradient(
                    colors: [
                        Theme.accentSoft.opacity(0.6),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.brandGradient)
                                                : AnyShapeStyle(Color.secondary))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? Theme.accentSoft
                          : (hovering ? Theme.hoverFill : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentRing : Color.clear,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

// MARK: - Background orbs (theme-adaptive)

struct BackgroundOrbs: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let alphaA: Double = scheme == .dark ? 0.20 : 0.10
        let alphaB: Double = scheme == .dark ? 0.18 : 0.08
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(Color(hex: 0x0A84FF, alpha: alphaA))
                    .frame(width: 480, height: 480)
                    .blur(radius: 120)
                    .offset(x: -geo.size.width * 0.25, y: -geo.size.height * 0.30)
                Circle()
                    .fill(Color(hex: 0x7C5CFF, alpha: alphaB))
                    .frame(width: 560, height: 560)
                    .blur(radius: 140)
                    .offset(x: geo.size.width * 0.30, y: geo.size.height * 0.30)
            }
            // Rasterize the heavy blurs into one cached Metal layer so they
            // aren't recomputed every time the detail content swaps on a tab
            // switch. These orbs are purely decorative (no material/vibrancy),
            // so flattening them is safe.
            .drawingGroup()
            .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager.shared)
        .frame(width: 1100, height: 720)
}
