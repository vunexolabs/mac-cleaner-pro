import SwiftUI
import Core

// MARK: - Layout

/// One placed segment in the sunburst. `depth = 0` is the innermost ring
/// (direct children of the focus node).
struct SunburstSegment: Identifiable, Hashable {
    let id: UUID
    let node: SpaceLensNode
    let depth: Int
    let startAngle: Double   // radians, measured CCW from +x axis
    let endAngle: Double
    let hue: Double          // 0…1 (HSL)
}

/// Builds a flat list of segments for `focus` going `maxDepth` levels deep.
/// Segments narrower than ~0.5° are skipped (they'd be invisible anyway).
struct SunburstLayout {
    let segments: [SunburstSegment]
    let maxDepth: Int

    /// Hue for a top-level child — the angular midpoint of its share, which is
    /// what `build` assigns at depth 0. Shared so the sidebar dots and the
    /// treemap tiles colour a folder identically to its slice here.
    static func topLevelHue(forChildAt idx: Int, of parent: SpaceLensNode) -> Double {
        let totalSpan = 2 * Double.pi
        let total = Double(parent.size)
        guard total > 0 else { return 0 }
        var current: Double = 0
        for (i, child) in parent.children.enumerated() {
            let span = totalSpan * Double(child.size) / total
            if i == idx { return (current + span / 2) / totalSpan }
            current += span
        }
        return 0
    }

    static func build(focus: SpaceLensNode, maxDepth: Int = 4) -> SunburstLayout {
        var segs: [SunburstSegment] = []
        addChildren(of: focus,
                    parentRange: (0, 2 * .pi),
                    depth: 0,
                    parentHue: nil,
                    segments: &segs,
                    maxDepth: maxDepth)
        return SunburstLayout(segments: segs, maxDepth: maxDepth)
    }

    private static func addChildren(
        of node: SpaceLensNode,
        parentRange: (Double, Double),
        depth: Int,
        parentHue: Double?,
        segments: inout [SunburstSegment],
        maxDepth: Int
    ) {
        guard depth < maxDepth, !node.children.isEmpty, node.size > 0 else { return }
        let totalSpan = parentRange.1 - parentRange.0
        let total = Double(node.size)
        let count = node.children.count
        var current = parentRange.0
        for (idx, child) in node.children.enumerated() {
            let frac = Double(child.size) / total
            let span = totalSpan * frac
            let end = current + span
            // Skip segments < ~0.5° — too thin to render, but also drop their subtrees.
            guard span >= 0.0087 else {
                current = end
                continue
            }
            // Top-level segments inherit a hue based on their angular position
            // around the wheel — produces a continuous rainbow at the
            // outermost layer. Children inherit parent hue with small jitter
            // so siblings look related but distinguishable.
            let hue: Double
            if let parentHue {
                let jitter = (Double(idx) - Double(count - 1) / 2.0) * 0.018
                hue = ((parentHue + jitter) + 1.0).truncatingRemainder(dividingBy: 1.0)
            } else {
                let centerAngle = (current + end) / 2.0
                hue = centerAngle / (2 * .pi)
            }
            segments.append(SunburstSegment(
                id: child.id,
                node: child,
                depth: depth,
                startAngle: current,
                endAngle: end,
                hue: hue
            ))
            addChildren(of: child,
                        parentRange: (current, end),
                        depth: depth + 1,
                        parentHue: hue,
                        segments: &segments,
                        maxDepth: maxDepth)
            current = end
        }
    }
}

// MARK: - View

struct SunburstView: View {
    let focus: SpaceLensNode
    let canAscend: Bool

    @Binding var hovering: SpaceLensNode?
    @Binding var selected: SpaceLensNode?

    let onSelect: (SpaceLensNode) -> Void
    let onDrill: (SpaceLensNode) -> Void
    let onAscend: () -> Void

    private static let maxDepth: Int = 4

    private var layout: SunburstLayout {
        SunburstLayout.build(focus: focus, maxDepth: Self.maxDepth)
    }

    var body: some View {
        GeometryReader { geo in
            let canvasSide = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxRadius = canvasSide / 2 - 16
            let hubRadius = max(64, maxRadius * 0.22)
            let ringWidth = (maxRadius - hubRadius) / Double(Self.maxDepth)

            ZStack {
                // Soft accent halo behind the wheel — gives the disc a warm glow.
                Circle()
                    .fill(RadialGradient(
                        colors: [Theme.accent.opacity(0.18), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: maxRadius * 1.25
                    ))
                    .frame(width: canvasSide * 1.4, height: canvasSide * 1.4)
                    .position(center)
                    .allowsHitTesting(false)

                // The sunburst itself.
                Canvas(rendersAsynchronously: false) { context, _ in
                    drawSegments(
                        context: context,
                        center: center,
                        hubRadius: hubRadius,
                        ringWidth: ringWidth
                    )
                }
                .allowsHitTesting(false)            // hover/click handled below

                // Invisible hit-test overlay — captures pointer for both hover and click.
                hitOverlay(
                    center: center,
                    hubRadius: hubRadius,
                    ringWidth: ringWidth,
                    maxRadius: maxRadius
                )

                // Center hub. Click to ascend if there's a parent.
                centerHub(hubRadius: hubRadius)
                    .position(center)
            }
            .compositingGroup()
            .animation(.easeOut(duration: 0.25), value: focus.id)
            // The wheel is a Canvas with a pointer-driven hit overlay, so it is
            // unreachable without a mouse: nothing to focus, nothing to read.
            // Swap in a real control tree for assistive tech — same data, same
            // actions, navigable by keyboard and VoiceOver.
            .accessibilityRepresentation { accessibleWheel }
        }
    }

    // MARK: Accessible equivalent

    /// A button per first-level slice, largest first, each announcing its share
    /// of the parent. Activating drills in, exactly like clicking the slice.
    private var accessibleWheel: some View {
        let total = max(UInt64(1), focus.size)
        return VStack(alignment: .leading, spacing: 0) {
            if canAscend {
                Button("Go up to the enclosing folder", action: onAscend)
            }
            Text("\(focus.name.isEmpty ? "Root" : focus.name), \(byteString(focus.size)) across \(focus.children.count) items")
                .accessibilityAddTraits(.isHeader)
            ForEach(focus.children) { child in
                let share = Int((Double(child.size) / Double(total) * 100).rounded())
                Button {
                    onSelect(child)
                    onDrill(child)
                } label: {
                    Text("\(child.name), \(byteString(child.size)), \(share) percent")
                }
            }
        }
        .accessibilityLabel("Disk usage for \(focus.name.isEmpty ? "root" : focus.name)")
    }

    // MARK: Center hub

    private func centerHub(hubRadius: Double) -> some View {
        Button(action: onAscend) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                Circle()
                    .strokeBorder(Theme.border, lineWidth: 1)
                Circle()
                    .strokeBorder(Theme.accentRing.opacity(0.4), lineWidth: 1.5)
                    .scaleEffect(0.92)
                VStack(spacing: 4) {
                    if canAscend {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(focus.name.isEmpty ? "/" : focus.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                    Text(byteString(focus.size))
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.brandGradient)
                    Text(canAscend ? "click to go up" : "root")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                .frame(width: hubRadius * 1.7, height: hubRadius * 1.7)
            }
            .frame(width: hubRadius * 2, height: hubRadius * 2)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!canAscend)
    }

    // MARK: Hit overlay

    private func hitOverlay(
        center: CGPoint,
        hubRadius: Double,
        ringWidth: Double,
        maxRadius: Double
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = hit(at: p, center: center,
                                  hubRadius: hubRadius, ringWidth: ringWidth)
                    let newHover = seg?.node
                    if newHover?.id != hovering?.id { hovering = newHover }
                case .ended:
                    if hovering != nil { hovering = nil }
                }
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { event in
                        if let seg = hit(at: event.location, center: center,
                                         hubRadius: hubRadius, ringWidth: ringWidth) {
                            onDrill(seg.node)
                        }
                    }
            )
            .gesture(
                SpatialTapGesture(count: 1)
                    .onEnded { event in
                        if let seg = hit(at: event.location, center: center,
                                         hubRadius: hubRadius, ringWidth: ringWidth) {
                            selected = seg.node
                            onSelect(seg.node)
                        } else {
                            selected = nil
                        }
                    }
            )
    }

    // MARK: Drawing

    private func drawSegments(
        context: GraphicsContext,
        center: CGPoint,
        hubRadius: Double,
        ringWidth: Double
    ) {
        // Pass 1 — fills + radial gradients
        for seg in layout.segments {
            let inner = hubRadius + Double(seg.depth) * ringWidth
            let outer = inner + ringWidth - 1.5
            let path = ringSegmentPath(
                center: center, inner: inner, outer: outer,
                start: seg.startAngle, end: seg.endAngle
            )

            let baseColor = Color(hue: seg.hue, saturation: 0.62,
                                  brightness: 0.95 - Double(seg.depth) * 0.06)
            let edgeColor = Color(hue: seg.hue, saturation: 0.78,
                                  brightness: 0.78 - Double(seg.depth) * 0.04)

            context.fill(
                path,
                with: .radialGradient(
                    Gradient(colors: [baseColor.opacity(0.55), edgeColor.opacity(0.95)]),
                    center: center,
                    startRadius: inner,
                    endRadius: outer
                )
            )

            // Highlight overlays
            let isHover    = hovering?.id == seg.node.id
            let isSelected = selected?.id == seg.node.id
            let isLineage  = isInLineageOfHovered(seg)

            if isSelected {
                context.fill(path, with: .color(.white.opacity(0.22)))
            } else if isHover {
                context.fill(path, with: .color(.white.opacity(0.14)))
            } else if isLineage {
                context.fill(path, with: .color(.white.opacity(0.06)))
            }

            // Border
            context.stroke(
                path,
                with: .color(isSelected ? .white : .black.opacity(0.20)),
                lineWidth: isSelected ? 1.6 : 0.8
            )
        }

        // Pass 2 — labels (drawn on top of all fills so they read clearly)
        for seg in layout.segments {
            let inner = hubRadius + Double(seg.depth) * ringWidth
            let outer = inner + ringWidth - 1.5
            let sweep = seg.endAngle - seg.startAngle
            let midR = (inner + outer) / 2
            let arcLen = sweep * midR
            // Heuristic: only label if there's room for ~6 chars at 10pt
            guard arcLen > 56, (outer - inner) > 26 else { continue }
            drawSegmentLabel(
                context: context,
                seg: seg,
                center: center,
                inner: inner,
                outer: outer
            )
        }
    }

    private func drawSegmentLabel(
        context: GraphicsContext,
        seg: SunburstSegment,
        center: CGPoint,
        inner: Double,
        outer: Double
    ) {
        let mid = (seg.startAngle + seg.endAngle) / 2
        let r = (inner + outer) / 2
        let x = center.x + cos(mid) * r
        let y = center.y + sin(mid) * r

        let resolved = context.resolve(
            Text(seg.node.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        )
        let textSize = resolved.measure(in: CGSize(width: 200, height: 30))
        let maxArc = (seg.endAngle - seg.startAngle) * r - 8
        if textSize.width > maxArc { return }

        // Tangent rotation, kept upright (don't flip text upside-down on bottom half).
        var rotation = mid + .pi / 2
        if rotation > .pi { rotation -= .pi }

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: x, y: y)
        t = t.rotated(by: rotation - .pi / 2)
        t = t.translatedBy(x: -textSize.width / 2, y: -textSize.height / 2)

        context.drawLayer { layer in
            layer.transform = t
            // Subtle text shadow for readability over bright tiles
            layer.draw(
                Text(seg.node.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.black.opacity(0.55)),
                at: CGPoint(x: 0.5, y: 0.5)
            )
            layer.draw(resolved, at: .zero)
        }
    }

    // MARK: Geometry helpers

    private func ringSegmentPath(
        center: CGPoint,
        inner: Double, outer: Double,
        start: Double, end: Double
    ) -> Path {
        var p = Path()
        let startA = Angle.radians(start)
        let endA = Angle.radians(end)
        // Outer arc (CCW in math; SwiftUI's coordinate system is y-down so visually CCW).
        p.addArc(center: center, radius: outer,
                 startAngle: startA, endAngle: endA, clockwise: false)
        // Line down to inner-end
        let innerEnd = CGPoint(
            x: center.x + cos(end) * inner,
            y: center.y + sin(end) * inner
        )
        p.addLine(to: innerEnd)
        // Inner arc back (CW)
        p.addArc(center: center, radius: inner,
                 startAngle: endA, endAngle: startA, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func hit(
        at point: CGPoint,
        center: CGPoint,
        hubRadius: Double,
        ringWidth: Double
    ) -> SunburstSegment? {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let r = sqrt(dx*dx + dy*dy)
        guard r > hubRadius else { return nil }
        var ang = atan2(dy, dx)
        if ang < 0 { ang += 2 * .pi }
        for seg in layout.segments {
            let inner = hubRadius + Double(seg.depth) * ringWidth
            let outer = inner + ringWidth - 1.5
            if r >= inner && r <= outer && ang >= seg.startAngle && ang <= seg.endAngle {
                return seg
            }
        }
        return nil
    }

    /// Returns true if `seg` is an ancestor of the currently hovered segment.
    /// Used to softly highlight the entire radial slice from center outward.
    private func isInLineageOfHovered(_ seg: SunburstSegment) -> Bool {
        guard let hov = hovering, hov.id != seg.node.id else { return false }
        guard let target = layout.segments.first(where: { $0.node.id == hov.id }) else {
            return false
        }
        return target.depth > seg.depth
            && target.startAngle >= seg.startAngle
            && target.endAngle <= seg.endAngle
    }
}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
