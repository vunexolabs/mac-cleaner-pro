import SwiftUI

// MARK: - Glass card

private struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.rLg
    var padded: Bool = true
    func body(content: Content) -> some View {
        content
            .padding(padded ? Layout.s4 : 0)
            // Material over the mild dark canvas resolved as a flat grey patch
            // with no sense of depth. An explicit elevated surface reads as a
            // card in both modes, and keeps the light appearance as it was.
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
                    .background(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Applies the glass-card treatment used everywhere in the app.
    func glassCard(radius: CGFloat = Theme.rLg, padded: Bool = true) -> some View {
        modifier(GlassCard(radius: radius, padded: padded))
    }
}

// MARK: - Eyebrow (uppercase tracking + dot)

struct Eyebrow: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            PulsingDot(size: 5)
            Text(text)
                .font(Theme.Text.eyebrow)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule().strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?

    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.s2) {
            if let eyebrow {
                Eyebrow(text: eyebrow)
            }
            Text(title)
                .font(Theme.Text.title)
                .tracking(-0.4)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Gradient (primary) button

struct GradientButtonStyle: ButtonStyle {
    var disabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.control.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Layout.s4)
            .padding(.vertical, Layout.s2 + 1)
            .background(
                Capsule()
                    .fill(disabled
                          ? AnyShapeStyle(Color.gray.opacity(0.3))
                          : AnyShapeStyle(Theme.brandGradient))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: disabled ? .clear : Theme.accentRing,
                    radius: configuration.isPressed ? 6 : 12,
                    y: configuration.isPressed ? 2 : 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75),
                       value: configuration.isPressed)
            .opacity(disabled ? 0.6 : 1.0)
    }
}

// MARK: - Soft (secondary) button

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.control)
            .foregroundStyle(.primary)
            .padding(.horizontal, Layout.s3 + 2)
            .padding(.vertical, Layout.s2 - 1)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule().strokeBorder(Theme.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75),
                       value: configuration.isPressed)
    }
}

// MARK: - Safety / status chips

struct StatusChip: View {
    enum Kind { case safe, review, destructive, helper, info }
    let kind: Kind
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Text.eyebrow)
            .foregroundStyle(color)
            .padding(.horizontal, Layout.s2 - 1)
            .padding(.vertical, Layout.s1 / 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.34), lineWidth: 1))
    }

    private var color: Color {
        switch kind {
        case .safe:        return Theme.ok
        case .review:      return Theme.warn
        case .destructive: return Theme.bad
        case .helper:      return Theme.warn
        case .info:        return Theme.accent
        }
    }
}

// MARK: - Logo mark

struct LogoMark: View {
    var size: CGFloat = 22
    var body: some View {
        // The transparent mark, not NSApp.applicationIconImage. The app icon is
        // deliberately full-bleed white so macOS can mask it into its own
        // squircle, which is right on the Dock and wrong in a dark sidebar,
        // where it drew as a white tile around the logo.
        Image(nsImage: Self.mark)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static let mark: NSImage = {
        if let url = Bundle.main.url(forResource: "mcp_logo_mark", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Falling back to the app icon keeps the lockup present rather than
        // blank if the resource ever goes missing.
        return NSApp.applicationIconImage
    }()
}

// MARK: - Gradient text

extension View {
    /// Apply the brand gradient as the foreground style (text only — equivalent
    /// to the marketing site's `.gradient-text` class).
    func brandGradientText() -> some View {
        self.foregroundStyle(Theme.brandGradient)
    }
}

// MARK: - Pulsing dot

/// Subtle breathing dot used in eyebrows and live indicators. Stays at base
/// opacity for users with reduced motion (system-respected).
struct PulsingDot: View {
    var color: Color = Theme.accent
    var size: CGFloat = 6
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(pulse ? 0.7 : 0.3), radius: pulse ? 6 : 3)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
