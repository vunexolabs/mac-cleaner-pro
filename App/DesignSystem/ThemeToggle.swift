import SwiftUI

/// Sun/moon button. Smooth icon swap mirrors the website's nav toggle.
struct ThemeToggle: View {
    @EnvironmentObject private var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                theme.toggle()
            }
        } label: {
            ZStack {
                ForEach(Appearance.allCases) { mode in
                    if mode == theme.appearance {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.brandGradient)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.4).combined(with: .opacity),
                                removal: .scale(scale: 1.4).combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(hovering ? Theme.hoverFill : Color.clear)
            )
            .overlay(
                Circle().strokeBorder(hovering ? Theme.border : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Toggle theme")
        // Icon-only control: without an explicit label VoiceOver falls back to
        // the SF Symbol name ("sun.max.fill").
        .accessibilityLabel("Appearance")
        .accessibilityValue(theme.appearance.label)
        .accessibilityHint("Switches between light, dark and system appearance")
    }
}
