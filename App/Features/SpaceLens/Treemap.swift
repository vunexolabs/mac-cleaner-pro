import Foundation
import CoreGraphics
import Core

/// One placed rectangle in a treemap layout.
struct TreemapTile {
    let node: SpaceLensNode
    let frame: CGRect
}

/// Squarified treemap layout (Bruls / Huijsen / van Wijk, 2000).
///
/// > Note: nothing renders this yet. Space Lens ships the sunburst only; this
/// > layout is complete and unit-testable but has no view attached, so the UI
/// > and docs deliberately say "sunburst" rather than promising a treemap that
/// > isn't drawn. Wiring it up as a second view mode is a self-contained piece
/// > of work: feed it `node.children` and a `CGRect`, draw the returned tiles.
/// Produces tiles whose aspect ratios are kept close to 1.0, which is much
/// more legible than slice-and-dice. We accept a sorted-by-size-desc array
/// of children and pack them into `bounds`.
enum Treemap {
    static func layout(nodes: [SpaceLensNode], in bounds: CGRect) -> [TreemapTile] {
        guard !nodes.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let total = nodes.reduce(UInt64(0)) { $0 &+ $1.size }
        guard total > 0 else { return [] }

        // Convert raw byte sizes to areas that sum to bounds.area.
        let totalArea = Double(bounds.width) * Double(bounds.height)
        let scale = totalArea / Double(total)
        let scaledAreas = nodes.map { Double($0.size) * scale }

        var tiles: [TreemapTile] = []
        var remaining = bounds
        var queue = Array(zip(nodes, scaledAreas))

        while !queue.isEmpty {
            let row = takeBestRow(queue: &queue, in: remaining)
            remaining = layoutRow(row, in: remaining, tiles: &tiles)
        }
        return tiles
    }

    /// Greedily extends a row of items along the shorter side of `bounds`,
    /// stopping when adding the next item would worsen the worst aspect ratio.
    private static func takeBestRow(
        queue: inout [(SpaceLensNode, Double)],
        in bounds: CGRect
    ) -> [(SpaceLensNode, Double)] {
        let w = Double(min(bounds.width, bounds.height))
        var row: [(SpaceLensNode, Double)] = []
        while !queue.isEmpty {
            let next = queue[0]
            let candidate = row + [next]
            if row.isEmpty || worstAspect(candidate, w: w) <= worstAspect(row, w: w) {
                row.append(next)
                queue.removeFirst()
            } else {
                break
            }
        }
        return row
    }

    /// Worst (max) aspect ratio if `row` is laid out side-by-side along width `w`.
    private static func worstAspect(_ row: [(SpaceLensNode, Double)], w: Double) -> Double {
        guard !row.isEmpty, w > 0 else { return .greatestFiniteMagnitude }
        let s = row.reduce(0.0) { $0 + $1.1 }
        guard s > 0 else { return .greatestFiniteMagnitude }
        let rMax = row.map(\.1).max() ?? 0
        let rMin = row.map(\.1).min() ?? 0
        let w2 = w * w
        let s2 = s * s
        return max((w2 * rMax) / s2, s2 / (w2 * rMin))
    }

    /// Lays out `row` along the short side of `bounds`. Returns the leftover
    /// rect for the remaining items.
    private static func layoutRow(
        _ row: [(SpaceLensNode, Double)],
        in bounds: CGRect,
        tiles: inout [TreemapTile]
    ) -> CGRect {
        guard !row.isEmpty else { return bounds }
        let totalArea = row.reduce(0.0) { $0 + $1.1 }

        if bounds.width <= bounds.height {
            // Lay out horizontally across the top, fixed row height = totalArea / width
            let rowHeight = CGFloat(totalArea / Double(bounds.width))
            var x = bounds.minX
            for (node, area) in row {
                let w = CGFloat(area / Double(rowHeight))
                let frame = CGRect(x: x, y: bounds.minY, width: w, height: rowHeight)
                tiles.append(TreemapTile(node: node, frame: frame))
                x += w
            }
            return CGRect(
                x: bounds.minX,
                y: bounds.minY + rowHeight,
                width: bounds.width,
                height: bounds.height - rowHeight
            )
        } else {
            // Lay out vertically down the left, fixed column width = totalArea / height
            let colWidth = CGFloat(totalArea / Double(bounds.height))
            var y = bounds.minY
            for (node, area) in row {
                let h = CGFloat(area / Double(colWidth))
                let frame = CGRect(x: bounds.minX, y: y, width: colWidth, height: h)
                tiles.append(TreemapTile(node: node, frame: frame))
                y += h
            }
            return CGRect(
                x: bounds.minX + colWidth,
                y: bounds.minY,
                width: bounds.width - colWidth,
                height: bounds.height
            )
        }
    }
}
