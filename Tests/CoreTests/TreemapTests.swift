import XCTest
import CoreGraphics
@testable import Core

final class TreemapTests: XCTestCase {

    private func node(_ name: String, _ size: UInt64) -> SpaceLensNode {
        SpaceLensNode(url: URL(fileURLWithPath: "/tmp/\(name)"),
                      name: name,
                      size: size,
                      isDirectory: false,
                      children: [])
    }

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testEmptyInputProducesNoTiles() {
        XCTAssertTrue(Treemap.layout(nodes: [], in: bounds).isEmpty)
    }

    func testZeroSizedBoundsProduceNoTiles() {
        let nodes = [node("a", 100)]
        XCTAssertTrue(Treemap.layout(nodes: nodes, in: .zero).isEmpty)
        XCTAssertTrue(Treemap.layout(nodes: nodes, in: CGRect(x: 0, y: 0, width: 0, height: 300)).isEmpty)
    }

    /// Every node with a size gets placed exactly once.
    func testEveryNodeIsPlacedOnce() {
        let nodes = [node("a", 500), node("b", 300), node("c", 150), node("d", 50)]
        let tiles = Treemap.layout(nodes: nodes, in: bounds)

        XCTAssertEqual(tiles.count, nodes.count)
        XCTAssertEqual(Set(tiles.map(\.node.name)), Set(nodes.map(\.name)))
    }

    /// Area is the whole point of a treemap: a node holding half the bytes must
    /// get half the pixels. Tolerance is loose enough for float drift, tight
    /// enough to catch a genuinely wrong proportion.
    func testTileAreaIsProportionalToSize() {
        let nodes = [node("half", 500), node("quarter", 250),
                     node("eighth", 125), node("rest", 125)]
        let tiles = Treemap.layout(nodes: nodes, in: bounds)
        let totalBytes = Double(nodes.reduce(UInt64(0)) { $0 &+ $1.size })
        let totalArea = Double(bounds.width * bounds.height)

        for tile in tiles {
            let expectedShare = Double(tile.node.size) / totalBytes
            let actualShare = Double(tile.frame.width * tile.frame.height) / totalArea
            XCTAssertEqual(actualShare, expectedShare, accuracy: 0.01,
                           "\(tile.node.name) should occupy \(expectedShare) of the area")
        }
    }

    /// Tiles together account for the panel, without spilling outside it.
    func testTilesStayInsideBoundsAndCoverThem() {
        let nodes = (1...12).map { node("n\($0)", UInt64(1_000 / $0)) }
        let tiles = Treemap.layout(nodes: nodes, in: bounds)

        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.frame.minX, bounds.minX - 0.5)
            XCTAssertGreaterThanOrEqual(tile.frame.minY, bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(tile.frame.maxX, bounds.maxX + 0.5)
            XCTAssertLessThanOrEqual(tile.frame.maxY, bounds.maxY + 0.5)
            XCTAssertGreaterThan(tile.frame.width, 0)
            XCTAssertGreaterThan(tile.frame.height, 0)
        }

        let covered = tiles.reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }
        XCTAssertEqual(covered, Double(bounds.width * bounds.height),
                       accuracy: Double(bounds.width * bounds.height) * 0.02,
                       "tiles should account for the panel area")
    }

    /// Squarification's reason for existing: tiles shouldn't be slivers. A
    /// slice-and-dice layout fails this badly on a lopsided distribution.
    func testTilesAreRoughlySquare() {
        let nodes = [node("a", 600), node("b", 200), node("c", 120),
                     node("d", 60), node("e", 20)]
        let tiles = Treemap.layout(nodes: nodes, in: bounds)

        for tile in tiles {
            let ratio = max(tile.frame.width / tile.frame.height,
                            tile.frame.height / tile.frame.width)
            XCTAssertLessThan(ratio, 8.0,
                              "\(tile.node.name) is a sliver: aspect ratio \(ratio)")
        }
    }

    func testZeroTotalSizeProducesNoTiles() {
        let nodes = [node("a", 0), node("b", 0)]
        XCTAssertTrue(Treemap.layout(nodes: nodes, in: bounds).isEmpty)
    }

    func testSingleNodeFillsTheBounds() {
        let tiles = Treemap.layout(nodes: [node("only", 42)], in: bounds)
        XCTAssertEqual(tiles.count, 1)
        let f = tiles[0].frame
        XCTAssertEqual(Double(f.width * f.height),
                       Double(bounds.width * bounds.height),
                       accuracy: 1.0)
    }
}
