import Foundation

/// Graph-aware selection helpers for the workflow canvas. Pure functions over the persisted graph so they
/// are testable without a view; each returns the new selection and always keeps the starting nodes in it.
enum CanvasSelection {
    /// The nodes and everything that feeds them, directly or transitively.
    static func upstream(of ids: Set<UUID>, edges: [StudioEdge]) -> Set<UUID> {
        reach(from: ids, edges: edges, forward: false)
    }

    /// The nodes and everything they feed, directly or transitively.
    static func downstream(of ids: Set<UUID>, edges: [StudioEdge]) -> Set<UUID> {
        reach(from: ids, edges: edges, forward: true)
    }

    /// The whole connected flow around the nodes, ignoring wire direction.
    static func connected(to ids: Set<UUID>, edges: [StudioEdge]) -> Set<UUID> {
        var result = ids
        var frontier = Array(ids)
        while let id = frontier.popLast() {
            for edge in edges {
                let neighbour = edge.sourceID == id ? edge.targetID : edge.targetID == id ? edge.sourceID : nil
                if let neighbour, result.insert(neighbour).inserted { frontier.append(neighbour) }
            }
        }
        return result
    }

    /// Every node that is not currently selected.
    static func inverted(_ ids: Set<UUID>, nodes: [StudioNode]) -> Set<UUID> {
        Set(nodes.map(\.id)).subtracting(ids)
    }

    /// Every node of the same kind as any selected node.
    static func sameKind(as ids: Set<UUID>, nodes: [StudioNode]) -> Set<UUID> {
        let kinds = Set(nodes.filter { ids.contains($0.id) }.map(\.kind))
        return Set(nodes.filter { kinds.contains($0.kind) }.map(\.id)).union(ids)
    }

    private static func reach(from ids: Set<UUID>, edges: [StudioEdge], forward: Bool) -> Set<UUID> {
        var result = ids
        var frontier = Array(ids)
        while let id = frontier.popLast() {
            for edge in edges {
                let next = forward ? (edge.sourceID == id ? edge.targetID : nil) : (edge.targetID == id ? edge.sourceID : nil)
                if let next, result.insert(next).inserted { frontier.append(next) }
            }
        }
        return result
    }
}

/// Align and distribute, as in any design tool. Returns new card origins only for nodes that move.
enum NodeArrangement {
    enum Alignment: Sendable { case left, centerHorizontally, right, top, centerVertically, bottom }
    enum Axis: Sendable { case horizontal, vertical }

    static func align(_ nodes: [StudioNode], ids: Set<UUID>, _ alignment: Alignment) -> [UUID: CanvasPoint] {
        let targets = nodes.filter { ids.contains($0.id) }
        guard targets.count > 1 else { return [:] }
        let minX = targets.map(\.position.x).min()!, maxX = targets.map { $0.position.x + NodeLayout.cardWidth($0) }.max()!
        let minY = targets.map(\.position.y).min()!, maxY = targets.map { $0.position.y + NodeLayout.cardHeight($0) }.max()!
        var moved: [UUID: CanvasPoint] = [:]
        for node in targets {
            var origin = node.position
            switch alignment {
            case .left: origin.x = minX
            case .right: origin.x = maxX - NodeLayout.cardWidth(node)
            case .centerHorizontally: origin.x = (minX + maxX) / 2 - NodeLayout.cardWidth(node) / 2
            case .top: origin.y = minY
            case .bottom: origin.y = maxY - NodeLayout.cardHeight(node)
            case .centerVertically: origin.y = (minY + maxY) / 2 - NodeLayout.cardHeight(node) / 2
            }
            if origin != node.position { moved[node.id] = origin }
        }
        return moved
    }

    /// Keeps the outermost two nodes where they are and spaces the ones between so the gaps are equal.
    static func distribute(_ nodes: [StudioNode], ids: Set<UUID>, _ axis: Axis) -> [UUID: CanvasPoint] {
        let targets = nodes.filter { ids.contains($0.id) }
        guard targets.count > 2 else { return [:] }
        func start(_ node: StudioNode) -> Double { axis == .horizontal ? node.position.x : node.position.y }
        func length(_ node: StudioNode) -> Double { axis == .horizontal ? NodeLayout.cardWidth(node) : NodeLayout.cardHeight(node) }
        let ordered = targets.sorted { start($0) < start($1) }
        let span = ordered.map { start($0) + length($0) }.max()! - start(ordered[0])
        let gap = (span - ordered.map(length).reduce(0, +)) / Double(ordered.count - 1)
        var cursor = start(ordered[0])
        var moved: [UUID: CanvasPoint] = [:]
        for node in ordered {
            var origin = node.position
            if axis == .horizontal { origin.x = cursor } else { origin.y = cursor }
            if origin != node.position { moved[node.id] = origin }
            cursor += length(node) + gap
        }
        return moved
    }
}
