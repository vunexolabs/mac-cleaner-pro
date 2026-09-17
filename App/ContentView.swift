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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
        } detail: {
            ZStack {
                BackgroundOrbs()
                detailContent
            }
            // The canvas ignores the safe area; the content must not. Applying
            // ignoresSafeArea inside BackgroundOrbs expanded the whole detail
            // pane under the title bar and shifted the layout with it.
            .background(Theme.canvas.ignoresSafeArea())
            // No principal title: macOS 26 draws a glass capsule behind a
            // principal toolbar item, and it only repeated the large heading
            // sitting a few points below it.
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


    /// Reads the shipped version rather than a literal — the sidebar read
    /// "v1.0 · indie" while the app was on 1.0.5.
    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "v\(version) · indie"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand lockup
            HStack(spacing: 10) {
                LogoMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Cleaner Pro")
                        .font(Theme.Text.control.weight(.semibold))
                        .tracking(-0.2)
                    Text(Self.versionLine)
                        .font(Theme.Text.eyebrow)
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

            // Status pill, with the appearance toggle beside it.
            //
            // The toggle used to live in the toolbar, where macOS 26 draws its
            // own glass background behind every item — a persistent ring around
            // a control that already shows a background on hover. Down here we
            // own the chrome, so hover is the only background it has.
            HStack(spacing: 8) {
                PulsingDot(color: Theme.ok, size: 6)
                Text("All systems operational")
                    .font(Theme.Text.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                ThemeToggle()
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
                    .font(Theme.Text.rowTitle.weight(.semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.brandGradient)
                                                : AnyShapeStyle(Color.secondary))
                    .frame(width: 18)
                Text(item.title)
                    .font(Theme.Text.rowTitle.weight(isSelected ? .semibold : .medium))
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
        let alphaA: Double = scheme == .dark ? 0.22 : 0.10
        let alphaB: Double = scheme == .dark ? 0.20 : 0.08

        GeometryReader { geo in
            ZStack {
                orb(Color(hex: 0x0A84FF, alpha: alphaA), diameter: geo.size.width * 0.9)
                    .offset(x: -geo.size.width * 0.28, y: -geo.size.height * 0.34)
                orb(Color(hex: 0x7C5CFF, alpha: alphaB), diameter: geo.size.width * 1.0)
                    .offset(x: geo.size.width * 0.32, y: geo.size.height * 0.34)
            }
            .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
    }

    /// A soft glow drawn as a radial gradient rather than a blurred circle.
    ///
    /// The previous version blurred a `Circle` by 120–140pt inside a
    /// `.drawingGroup()`. That rasterises into a buffer the size of the view,
    /// so the blur — which bleeds well past the circle's own bounds — was
    /// hard-clipped at the buffer edge and drew a visible rectangle across
    /// every screen. It showed up twice as strongly in dark mode, where the
    /// alpha is doubled.
    ///
    /// A gradient has no bleed to clip, needs no offscreen buffer, and costs
    /// less than the blur it replaces.
    private func orb(_ color: Color, diameter: CGFloat) -> some View {
        RadialGradient(
            gradient: Gradient(colors: [color, color.opacity(0), .clear]),
            center: .center,
            startRadius: 0,
            endRadius: diameter / 2
        )
        .frame(width: diameter, height: diameter)
    }
}


#Preview {
    ContentView()
        .environmentObject(ThemeManager.shared)
        .frame(width: 1100, height: 720)
}
