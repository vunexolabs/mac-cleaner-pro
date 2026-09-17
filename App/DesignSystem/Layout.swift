import SwiftUI

// MARK: - Spacing

/// One spacing scale for the whole app, so padding is a decision made once
/// rather than re-guessed at each call site.
enum Layout {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 22
    static let s6: CGFloat = 28

    /// Comfortable reading measure for body copy in a card.
    static let proseMax: CGFloat = 560
}

// MARK: - Width class

/// How much horizontal room a view has actually been given.
///
/// The app previously assumed a window at least 980pt wide and hard-coded
/// widths against that assumption (a 280pt sidebar, a 210pt picker). Below
/// that, content clipped rather than reflowing. Views read this instead of
/// each deriving their own answer from a `GeometryReader`.
enum WidthClass: Comparable {
    case compact   // < 820 — single column, sidebars collapse
    case regular   // 820..<1200 — the common laptop case
    case wide      // >= 1200 — room for supporting detail

    init(width: CGFloat) {
        switch width {
        case ..<820:    self = .compact
        case ..<1200:   self = .regular
        default:        self = .wide
        }
    }

    /// True when a secondary panel should give way to the primary content.
    var collapsesSidebars: Bool { self == .compact }
}

private struct WidthClassKey: EnvironmentKey {
    static let defaultValue: WidthClass = .regular
}

extension EnvironmentValues {
    var widthClass: WidthClass {
        get { self[WidthClassKey.self] }
        set { self[WidthClassKey.self] = newValue }
    }
}

extension View {
    /// Publishes the receiver's width as a `WidthClass` to its subtree.
    /// Apply once, high up — `ContentView`'s detail pane — not per view.
    func publishesWidthClass() -> some View {
        modifier(WidthClassInjector())
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WidthClassInjector: ViewModifier {
    /// The *class*, not the raw width.
    ///
    /// Holding the pixel width here meant every pixel of a window drag wrote
    /// new state, which changed the environment, which re-rendered the whole
    /// detail subtree — charts included — hundreds of times per resize. The
    /// class only changes twice across the entire width of a screen, so
    /// storing that instead makes a drag almost free.
    @State private var widthClass: WidthClass = .regular

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                let next = WidthClass(width: newWidth)
                if next != widthClass { widthClass = next }
            }
            .environment(\.widthClass, widthClass)
    }
}
