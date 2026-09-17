import SwiftUI
import Core

/// Renders the squarified layout from ``Treemap`` as an interactive map.
///
/// Same contract as ``SunburstView`` — the two are interchangeable inside
/// Space Lens's chart panel, and share hover/selection bindings so the sidebar
/// stays in step whichever one is showing.
///
/// Area is the encoding: a tile's share of the panel is its share of the
/// folder. That is the treemap's advantage over the wheel — comparing two
/// rectangles is easier than comparing two arcs, and deep trees don't collapse
/// into unreadable slivers at the rim.
struct TreemapView: View {
    let focus: SpaceLensNode
    let canAscend: Bool

    @Binding var hovering: SpaceLensNode?
    @Binding var selected: SpaceLensNode?

    let onSelect: (SpaceLensNode) -> Void
    let onDrill: (SpaceLensNode) -> Void
    let onAscend: () -> Void

    /// Below this, a tile can't hold its name legibly and is left bare — the
    /// sidebar and the tooltip still name it.
    private static let minLabelWidth: CGFloat = 68
    private static let minLabelHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let tiles = Treemap.layout(nodes: focus.children, in: bounds)

            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.node.id) { index, tile in
                    let w = max(1, tile.frame.width)
                    let h = max(1, tile.frame.height)
                    tileView(for: tile, index: index, width: w, height: h)
                        .frame(width: w, height: h)
                        .position(x: tile.frame.midX, y: tile.frame.midY)
                }

                if canAscend {
                    ascendButton
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .animation(.easeOut(duration: 0.25), value: focus.id)
            // Tiles are hover- and click-driven with no text of their own once
            // they get small, so assistive tech gets the same control tree the
            // sunburst offers rather than a grid of anonymous rectangles.
            .accessibilityRepresentation { accessibleMap }
        }
    }

    // MARK: Tiles

    private func tileView(for tile: TreemapTile, index: Int, width: CGFloat, height: CGFloat) -> some View {
        let node = tile.node
        let isSelected = selected?.id == node.id
        let isHovering = hovering?.id == node.id
        // Same source of truth as the wheel, so a folder keeps its colour
        // when you switch charts.
        let hue = SunburstLayout.topLevelHue(forChildAt: index, of: focus)
        let fill = Color(hue: hue, saturation: 0.62, brightness: 0.95)

        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill.opacity(isHovering || isSelected ? 1.0 : 0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.9) : Color.white.opacity(0.35),
                        lineWidth: isSelected ? 2 : 0.75
                    )
            )
            .overlay(alignment: .topLeading) {
                if width >= Self.minLabelWidth && height >= Self.minLabelHeight {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(Theme.Text.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(byteString(node.size))
                            .font(Theme.Text.metric)
                            .opacity(0.75)
                    }
                    // The tile colours are fixed pastels, so dark text reads on
                    // them in either app appearance — .primary would invert.
                    .foregroundStyle(Color.black.opacity(0.78))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    if hovering?.id != node.id { hovering = node }
                } else if hovering?.id == node.id {
                    hovering = nil
                }
            }
            .onTapGesture {
                selected = node
                onSelect(node)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if node.isDirectory && !node.children.isEmpty { onDrill(node) }
            })
            .help("\(node.name) — \(byteString(node.size))")
    }

    private var ascendButton: some View {
        Button(action: onAscend) {
            Label("Up", systemImage: "arrow.up.left")
                .font(Theme.Text.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(.regularMaterial)
                )
                .overlay(
                    Capsule().strokeBorder(Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Go up to the enclosing folder")
        .accessibilityLabel("Go up to the enclosing folder")
    }

    // MARK: Accessible equivalent

    /// Mirrors ``SunburstView``'s representation: one button per child, largest
    /// first, announcing its share. Activating drills in.
    private var accessibleMap: some View {
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
                    selected = child
                    onSelect(child)
                    if child.isDirectory && !child.children.isEmpty { onDrill(child) }
                } label: {
                    Text("\(child.name), \(byteString(child.size)), \(share) percent")
                }
            }
        }
        .accessibilityLabel("Disk usage map for \(focus.name.isEmpty ? "root" : focus.name)")
    }

}

private func byteString(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
