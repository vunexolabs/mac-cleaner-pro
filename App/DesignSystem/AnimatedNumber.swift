import SwiftUI

/// Tweens a Double to its target value when it changes — used for the
/// "Reclaimable: 6.36 GB" counter so the number rolls in instead of popping.
struct AnimatedByteCount: View, Animatable {
    var value: Double
    var font: Font = Theme.Text.metricLarge
    var color: Color = .primary

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let bytes = max(0, Int64(value))
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        Text(formatted)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            // The text changes on every frame of the tween. Without this,
            // VoiceOver chases the animation and reads a stream of partial
            // numbers; the value is what matters, so announce only that.
            .accessibilityValue(formatted)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
