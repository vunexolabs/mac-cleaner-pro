import SwiftUI
import Core

private enum OnboardingStep: Int, CaseIterable {
    case welcome, fullDiskAccess, finish
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var fdaGranted: Bool = FullDiskAccess.isGranted()

    var body: some View {
        ZStack {
            BackgroundOrbs()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.3)
                footer.padding(20)
            }
        }
        .frame(width: 680, height: 500)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:        welcome
        case .fullDiskAccess: fullDiskAccess
        case .finish:         finish
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: Theme.accentRing, radius: 24, y: 10)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("Welcome to Mac Cleaner Pro")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.6)
                Text("Finally see what's hiding in System Data.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.brandGradient)
            }
            Text("Apple's storage panel hides System Data behind a single opaque number. We break it down rule-by-rule. Every clean is reversible — files stage in your Trash and stay restorable for 30 days, unless you empty the Trash yourself.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 24) {
                FeaturePill(icon: "lock.shield.fill", text: "Local-only")
                FeaturePill(icon: "arrow.uturn.backward.circle.fill", text: "30-day undo")
                FeaturePill(icon: "checkmark.seal.fill", text: "Free & open source")
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(40)
    }

    private var fullDiskAccess: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(fdaGranted ? Theme.ok.opacity(0.15) : Theme.warn.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: fdaGranted ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(fdaGranted ? Theme.ok : Theme.warn)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Step 2 of 3")
                    Text("Full Disk Access")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.4)
                }
                Spacer()
            }

            Text("To break down System Data — caches, logs, developer artifacts, and app leftovers across your account — Mac Cleaner Pro needs Full Disk Access. Without it, scans miss most of what's reclaimable.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                StepLine(num: 1, text: "Click **Open System Settings** below.")
                StepLine(num: 2, text: "Toggle **Mac Cleaner Pro** on under Privacy & Security → Full Disk Access.")
                StepLine(num: 3, text: "Return here and click **Re-check**.")
            }
            .padding(14)
            .glassCard(padded: false)

            HStack(spacing: 10) {
                Button {
                    FullDiskAccess.openSystemSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(GradientButtonStyle())
                Button("Re-check") { fdaGranted = FullDiskAccess.isGranted() }
                    .buttonStyle(SoftButtonStyle())
                Spacer()
                if fdaGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ok)
                } else {
                    Text("Not granted yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.warn)
                }
            }
            Spacer()
        }
        .padding(40)
    }

    private var finish: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.ok.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.ok)
            }
            VStack(spacing: 6) {
                Text("You're all set").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                Text("Time to demystify System Data.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            Text("Run **Smart Scan** to see what's reclaimable. System-level cleanup is gated until we ship a notarized helper — those rules show with a 'Requires helper' badge.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Spacer()
        }
        .padding(40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? AnyShapeStyle(Theme.brandGradient)
                                    : AnyShapeStyle(Color.secondary.opacity(0.25)))
                    .frame(width: s == step ? 28 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
            }
            Spacer()
            if step != .welcome {
                Button("Back") {
                    if let prev = OnboardingStep(rawValue: step.rawValue - 1) { step = prev }
                }
                .buttonStyle(SoftButtonStyle())
            }
            if step == .finish {
                Button {
                    OnboardingState.hasCompleted = true
                    onFinish()
                } label: {
                    Label("Get Started", systemImage: "sparkles")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    if let next = OnboardingStep(rawValue: step.rawValue + 1) { step = next }
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

private struct StepLine: View {
    let num: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 22, height: 22)
                Text("\(num)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.accent)
            }
            Text(.init(text))
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
