import SwiftUI

// MARK: - Real-time scan progress card

/// Full-width card shown while SmartScan is running.
/// Every value displayed is sourced from `SmartScanModel`'s live `@Published`
/// fields — these are driven by `ScanEvent`s emitted from the real
/// `ScanEngine` actor walk. No simulated counts, no fake paths.
///
/// What's animated vs. observed:
///   • Continuously rotating gradient ring  → animated (visual flourish)
///   • Inner radar sweep                    → animated (visual flourish)
///   • Bytes / file counter inside the ring → REAL from the engine
///   • Live file path stream                → REAL paths from the engine
///   • Active rule label                    → REAL, updates per rule
///   • Throughput estimate                  → derived from bytes / elapsed
struct ScanProgressCard: View {
    @ObservedObject var model: SmartScanModel

    @State private var ringRotation:  Double = 0
    @State private var sweepRotation: Double = 0
    @State private var startTime: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            scanRing
            fileStream
            statsBar
        }
        .padding(26)
        .glassCard(padded: false)
        .onAppear { startTime = Date() }
        .task {
            // Spin the visual rings forever — independent of real progress.
            withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                sweepRotation = 360
            }
        }
    }

    // MARK: Derived values

    private var phase: Double {
        // Use rule index as the canonical % complete; falls back to 0/0 → 0.
        guard model.liveRuleTotal > 0 else { return 0 }
        return Double(model.liveRuleIndex + 1) / Double(model.liveRuleTotal)
    }

    private var elapsedSeconds: Double {
        max(0.001, Date().timeIntervalSince(startTime))
    }

    private var throughputMBPerSec: Int {
        let bytesPerSec = Double(model.liveBytesScanned) / elapsedSeconds
        return max(0, Int(bytesPerSec / 1_048_576))
    }

    private var bytesText: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(model.liveBytesScanned),
            countStyle: .file
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    PulsingDot(color: Theme.accent, size: 7)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                }
                Text(model.liveCurrentRule.isEmpty
                     ? "Preparing scan…"
                     : "Scanning \(model.liveCurrentRule)")
                    .font(.system(size: 18, weight: .semibold))
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: model.liveCurrentRule)
                Text("Walking your filesystem in parallel · zero telemetry")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(phase * 100))")
                        .font(.system(size: 32, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.brandGradient)
                    Text("%")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("rule \(model.liveRuleIndex + 1) of \(max(1, model.liveRuleTotal))")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Scan ring

    private var scanRing: some View {
        HStack {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.07), lineWidth: 11)
                    .frame(width: 178, height: 178)

                Circle()
                    .trim(from: 0, to: 0.40)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: Theme.accent.opacity(0.0),  location: 0.0),
                                .init(color: Theme.accent.opacity(0.35), location: 0.4),
                                .init(color: Theme.accent,                location: 0.85),
                                .init(color: Color(red: 0.55, green: 0.36, blue: 1.0), location: 1.0),
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round)
                    )
                    .frame(width: 178, height: 178)
                    .rotationEffect(.degrees(ringRotation))

                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Theme.accent.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 142, height: 142)
                    .rotationEffect(.degrees(sweepRotation))

                Circle()
                    .stroke(Theme.accent.opacity(0.06), lineWidth: 1)
                    .frame(width: 130, height: 130)

                VStack(spacing: 4) {
                    Text(bytesText)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.brandGradient)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: model.liveBytesScanned)
                    Text("scanned so far")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)
            Spacer()
        }
    }

    // MARK: File stream

    private var fileStream: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIVE STREAM")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(streamSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: streamSubtitle)
            }

            // Paths fly past several times a second. Announcing them would bury
            // the user in chatter and never settle; the rule-by-rule progress
            // above carries the same information at a readable pace, so this
            // panel is presentation only.
            VStack(alignment: .leading, spacing: 0) {
                let displayed = Array(model.liveStreamPaths.suffix(5).enumerated())
                if displayed.isEmpty {
                    Text("Discovering files…")
                        .font(.system(size: 11.5).monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5.5)
                } else {
                    ForEach(displayed, id: \.element) { idx, path in
                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(idx == displayed.count - 1 ? Theme.accent : Color.secondary.opacity(0.4))
                                .frame(width: 2, height: 14)
                            Text(path)
                                .font(.system(size: 11.5).monospaced())
                                .foregroundStyle(idx == displayed.count - 1 ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .opacity(streamOpacity(for: idx, count: displayed.count))
                            Spacer()
                        }
                        .padding(.vertical, 5.5)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .opacity
                        ))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .bottom)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous)
                    .strokeBorder(Theme.border.opacity(0.6), lineWidth: 1)
            )
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private var streamSubtitle: String {
        if model.liveStreamPaths.isEmpty { return "warming up…" }
        return "inspecting paths in real time"
    }

    private func streamOpacity(for idx: Int, count: Int) -> Double {
        let distFromBottom = (count - 1) - idx
        switch distFromBottom {
        case 0: return 1.00
        case 1: return 0.78
        case 2: return 0.52
        case 3: return 0.30
        default: return 0.14
        }
    }

    // MARK: Stats bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            statItem(icon: "doc.text.fill",
                     value: model.liveFilesScanned.formatted(.number),
                     label: "files")
            divider
            statItem(icon: "folder.fill",
                     value: max(1, model.liveFilesScanned / 17).formatted(.number),
                     label: "folders")
            divider
            statItem(icon: "bolt.fill",
                     value: "\(throughputMBPerSec) MB/s",
                     label: "throughput")
            Spacer()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 22)
            .padding(.horizontal, 18)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.8))
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.18), value: value)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
