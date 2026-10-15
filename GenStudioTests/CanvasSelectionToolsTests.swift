import XCTest
@testable import GenStudio

final class CanvasSelectionToolsTests: XCTestCase {
    private func node(_ x: Double, _ y: Double, kind: NodeKind = .prompt) -> StudioNode {
        StudioNode(kind: kind, label: "N", position: .init(x: x, y: y))
    }
    private func edge(_ a: StudioNode, _ b: StudioNode) -> StudioEdge { StudioEdge(sourceID: a.id, targetID: b.id, type: .text) }

    func testUpstreamDownstreamAndConnected() {
        let a = node(0, 0), b = node(300, 0), c = node(600, 0), lone = node(0, 400)
        let edges = [edge(a, b), edge(b, c)]
        XCTAssertEqual(CanvasSelection.upstream(of: [c.id], edges: edges), [a.id, b.id, c.id])
        XCTAssertEqual(CanvasSelection.downstream(of: [a.id], edges: edges), [a.id, b.id, c.id])
        XCTAssertEqual(CanvasSelection.connected(to: [b.id], edges: edges), [a.id, b.id, c.id])
        XCTAssertFalse(CanvasSelection.connected(to: [b.id], edges: edges).contains(lone.id))
    }

    func testInvertAndSameKind() {
        let a = node(0, 0), b = node(300, 0, kind: .imageInput), c = node(600, 0)
        XCTAssertEqual(CanvasSelection.inverted([a.id], nodes: [a, b, c]), [b.id, c.id])
        XCTAssertEqual(CanvasSelection.sameKind(as: [a.id], nodes: [a, b, c]), [a.id, c.id])
    }

    func testAlignLeftAndDistribute() {
        let a = node(0, 0), b = node(500, 50), c = node(1000, 90)
        let left = NodeArrangement.align([a, b, c], ids: [a.id, b.id, c.id], .left)
        XCTAssertNil(left[a.id])
        XCTAssertEqual(left[b.id]?.x, 0)
        XCTAssertEqual(left[c.id]?.x, 0)
        let spread = NodeArrangement.distribute([a, b, c], ids: [a.id, b.id, c.id], .horizontal)
        let gapAB = (spread[b.id]?.x ?? b.position.x) - (a.position.x + NodeLayout.cardWidth(a))
        let gapBC = c.position.x - ((spread[b.id]?.x ?? b.position.x) + NodeLayout.cardWidth(b))
        XCTAssertEqual(gapAB, gapBC, accuracy: 0.01)
        XCTAssertTrue(NodeArrangement.distribute([a, b], ids: [a.id, b.id], .horizontal).isEmpty, "Distribute needs three nodes")
    }
}
