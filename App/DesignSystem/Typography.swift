import SwiftUI

// MARK: - Semantic type scale

/// The app's type roles, expressed as *relative* system styles.
///
/// Why this exists: the UI was written with ~225 literal `.system(size: 13)`
/// calls. A fixed point size ignores the system text-size setting entirely, so
/// the whole app stayed the same size no matter what the user chose in
/// Accessibility → Display → Text Size. Relative styles (`.system(.body, …)`)
/// scale with it, which is the difference between an app someone can use all
/// day and one they can't.
///
/// Sizes here are chosen to land close to the literals they replace at the
/// default text size, so migrating a view is a like-for-like swap rather than
/// a redesign.
extension Theme {
    enum Text {
        /// Hero numbers — the "6.36 GB reclaimable" headline.
        static let display = Font.system(.largeTitle, design: .default, weight: .semibold)
        /// Screen titles ("Space Lens").
        static let title = Font.system(.title, design: .default, weight: .semibold)
        /// Card and section headings.
        static let sectionTitle = Font.system(.headline, design: .default, weight: .semibold)
        /// Emphasised row labels — file names, app names.
        static let rowTitle = Font.system(.callout, design: .default, weight: .medium)
        /// Default reading text.
        static let body = Font.system(.callout)
        /// Buttons and compact controls.
        static let control = Font.system(.callout, design: .default, weight: .medium)
        /// Secondary descriptions under a title.
        static let caption = Font.system(.caption)
        /// The uppercase tracked eyebrow above a section header.
        static let eyebrow = Font.system(.caption2, design: .default, weight: .semibold)

        /// Any figure that animates or updates in place. Monospaced digits stop
        /// the surrounding layout jittering as the value counts up.
        static let metric = Font.system(.callout, design: .default, weight: .semibold).monospacedDigit()
        /// Large animated figure (Smart Scan total, memory gauge).
        static let metricLarge = Font.system(.title, design: .default, weight: .semibold).monospacedDigit()
        /// Paths in the live scan stream.
        static let mono = Font.system(.caption, design: .monospaced)
    }
}
