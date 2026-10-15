import Foundation

/// Presentation-only layout. It changes node positions, never graph semantics.
///
/// Organising happens in two stages. Each *pocket* — a flow the author can
/// point at, made of everything wired together plus the loose cards sitting
/// with it — is laid out on its own by `LayeredFlowLayout`. The pockets are
/// then repacked into a board of roughly screen proportions, largest first,
/// so the result reads top-left to bottom-right instead of trailing off in one
/// endless strip.
///
/// The authored arrangement is not preserved as geometry, but it is not thrown
/// away either: it orders the pockets' contents and decides which flow a loose
/// card belongs to, so a tidied board still reads in the order the author
/// built it.
enum WorkflowAutoLayout {
    /// Clearance between two pockets.
    static let pocketGap = 160.0
    /// Clearance between a flow and the loose cards parked beneath it.
    static let satelliteGap = 48.0
    /// The narrowest a row of parked loose cards may wrap at.
    static let satelliteRowWidth = 640.0
    /// Pockets are packed towards this shape rather than one long row.
    static let boardAspect = 16.0 / 9.0

    private struct Pocket {
        var ids: [UUID]
        var positions: [UUID: CanvasPoint]
        var size: CGSize
        var authored: CGRect
        var order: (Double, Double, String)
    }

    /// Tidies `nodes`. Passing two or more ids as `scope` tidies only those,
    /// in place, and leaves the rest of the board untouched.
    static func positions(nodes: [StudioNode], edges: [StudioEdge], scope: Set<UUID>? = nil) -> [UUID: CanvasPoint] {
        var seen = Set<UUID>()
        var subject = nodes.filter { seen.insert($0.id).inserted }
        if let scope {
            let scoped = subject.filter { scope.contains($0.id) }
            if scoped.count > 1 { subject = scoped }
        }
        guard !subject.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: subject.map { ($0.id, $0) })
        let wires = Set(edges.compactMap { edge -> LayeredFlowLayout.Wire? in
            guard edge.sourceID != edge.targetID, byID[edge.sourceID] != nil, byID[edge.targetID] != nil else { return nil }
            return .init(source: edge.sourceID, target: edge.targetID)
        })
        let engine = LayeredFlowLayout()
        let card: (UUID) -> LayeredFlowLayout.Card = { id in
            guard let node = byID[id] else { return .init(width: 0, height: 0) }
            return .init(width: NodeLayout.cardWidth(node), height: NodeLayout.cardHeight(node),
                         leading: NodeLayout.leadingOverflow(node), trailing: NodeLayout.trailingOverflow(node))
        }
        let authored: (UUID) -> CanvasPoint = { byID[$0]?.position ?? .init(x: 0, y: 0) }

        var pockets = connectedGroups(subject, wires).map { ids -> Pocket in
            let inner = wires.filter { ids.contains($0.source) && ids.contains($0.target) }
            let local = engine.positions(ids: Array(ids), wires: Array(inner), card: card, authored: authored)
            return pocket(ids: Array(ids), positions: local, card: card, authored: authored)
        }
        pockets = adoptLooseCards(in: pockets, card: card, authored: authored)
        let placed = pack(pockets)

        var result: [UUID: CanvasPoint] = [:]
        for pocket in placed {
            for (id, position) in pocket.positions { result[id] = position }
        }
        return anchored(result, to: subject, card: card)
    }

    // MARK: - Pockets

    /// Everything wired together, directly or indirectly. A loose card is its
    /// own group here; `adoptLooseCards` decides where it belongs.
    private static func connectedGroups(_ nodes: [StudioNode], _ wires: Set<LayeredFlowLayout.Wire>) -> [Set<UUID>] {
        var adjacency = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set<UUID>()) })
        for wire in wires {
            adjacency[wire.source, default: []].insert(wire.target)
            adjacency[wire.target, default: []].insert(wire.source)
        }
        var unseen = Set(nodes.map(\.id))
        var groups: [Set<UUID>] = []
        for node in nodes where unseen.contains(node.id) {
            unseen.remove(node.id)
            var stack = [node.id]
            var group: Set<UUID> = []
            while let id = stack.popLast() {
                group.insert(id)
                for next in (adjacency[id] ?? []).sorted(by: { $0.uuidString < $1.uuidString }) where unseen.remove(next) != nil {
                    stack.append(next)
                }
            }
            groups.append(group)
        }
        return groups
    }

    private static func pocket(
        ids: [UUID], positions: [UUID: CanvasPoint],
        card: (UUID) -> LayeredFlowLayout.Card, authored: (UUID) -> CanvasPoint
    ) -> Pocket {
        var laid = CGRect.null
        var drawn = CGRect.null
        var corner = CanvasPoint(x: 0, y: 0)
        var seenCorner = false
        for id in ids {
            let position: CanvasPoint = positions[id] ?? CanvasPoint(x: 0, y: 0)
            laid = laid.union(frame(of: id, at: position, card: card))
            let origin: CanvasPoint = authored(id)
            drawn = drawn.union(frame(of: id, at: origin, card: card))
            if !seenCorner || origin.y < corner.y || (origin.y == corner.y && origin.x < corner.x) {
                corner = origin
                seenCorner = true
            }
        }
        let key: String = ids.map(\.uuidString).min() ?? ""
        return .init(ids: ids, positions: positions, size: laid.isNull ? .zero : laid.size,
                     authored: drawn.isNull ? .zero : drawn, order: (corner.y, corner.x, key))
    }

    private static func frame(of id: UUID, at position: CanvasPoint, card: (UUID) -> LayeredFlowLayout.Card) -> CGRect {
        let measured = card(id)
        return CGRect(x: position.x - measured.leading, y: position.y,
                      width: measured.leading + measured.width + measured.trailing, height: measured.height)
    }

    /// A Sticky Note or a not-yet-wired input is part of the flow it was
    /// parked beside, so it travels with that flow instead of being packed off
    /// on its own. Every loose card joins its nearest flow: a distance
    /// threshold would decide differently once the card had been tidied next
    /// to that flow, and organising twice has to settle rather than shuffle.
    ///
    /// Satellites park in rows beneath their host, in the left-to-right order
    /// the author left them in.
    private static func adoptLooseCards(
        in pockets: [Pocket], card: (UUID) -> LayeredFlowLayout.Card, authored: (UUID) -> CanvasPoint
    ) -> [Pocket] {
        let hosts = pockets.enumerated().filter { $0.element.ids.count > 1 }
        guard !hosts.isEmpty else { return pockets }
        var adopted: [Int: [UUID]] = [:]
        for pocket in pockets where pocket.ids.count == 1 {
            let id = pocket.ids[0]
            let origin: CanvasPoint = authored(id)
            let point = CGPoint(x: origin.x, y: origin.y)
            var host = hosts[0].offset
            var nearest = Double.greatestFiniteMagnitude
            for candidate in hosts {
                let gap: Double = distance(from: point, to: candidate.element.authored)
                if gap < nearest {
                    nearest = gap
                    host = candidate.offset
                }
            }
            adopted[host, default: []].append(id)
        }
        guard !adopted.isEmpty else { return pockets }
        var result: [Pocket] = []
        for host in hosts {
            guard let satellites = adopted[host.offset] else { result.append(host.element); continue }
            var pocket = host.element
            let ordered = satellites.sorted {
                let a = authored($0), b = authored($1)
                return a.x == b.x ? (a.y == b.y ? $0.uuidString < $1.uuidString : a.y < b.y) : a.x < b.x
            }
            let limit = max(pocket.size.width, satelliteRowWidth)
            var cursor = 0.0, widest = 0.0
            var rowTop = pocket.size.height + satelliteGap, rowHeight = 0.0
            for id in ordered {
                let measured = card(id)
                let span = measured.leading + measured.width + measured.trailing
                if cursor > 0, cursor + span > limit {
                    rowTop += rowHeight + satelliteGap
                    cursor = 0; rowHeight = 0
                }
                pocket.positions[id] = .init(x: cursor + measured.leading, y: rowTop)
                pocket.ids.append(id)
                cursor += span + satelliteGap
                rowHeight = max(rowHeight, measured.height)
                widest = max(widest, cursor - satelliteGap)
            }
            pocket.size = CGSize(width: max(pocket.size.width, widest), height: rowTop + rowHeight)
            result.append(pocket)
        }
        return result
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        guard !rect.isNull, !rect.isEmpty else { return .greatestFiniteMagnitude }
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Packing

    /// First-fit decreasing height: tallest pockets first, filling each shelf
    /// left to right before starting the next. Sorting by height is what keeps
    /// the shelves from wasting a band of empty canvas, and it puts the main
    /// flow — nearly always the tallest — at the top left where reading starts.
    private static func pack(_ pockets: [Pocket]) -> [Pocket] {
        guard pockets.count > 1 else { return pockets }
        let sorted = pockets.sorted {
            if $0.size.height != $1.size.height { return $0.size.height > $1.size.height }
            if $0.size.width != $1.size.width { return $0.size.width > $1.size.width }
            return $0.order < $1.order
        }
        let area = sorted.reduce(0.0) { $0 + $1.size.width * $1.size.height }
        let widest = sorted.map(\.size.width).max() ?? 0
        let limit = max(widest, (area * boardAspect).squareRoot())
        var shelves: [(top: Double, height: Double, cursor: Double)] = []
        var result: [Pocket] = []
        for var pocket in sorted {
            let index = shelves.firstIndex { $0.cursor + pocket.size.width <= limit || $0.cursor == 0 }
                ?? shelves.count
            if index == shelves.count {
                let top = shelves.last.map { $0.top + $0.height + pocketGap } ?? 0
                shelves.append((top, pocket.size.height, 0))
            }
            let shelf = shelves[index]
            pocket.positions = pocket.positions.mapValues { .init(x: $0.x + shelf.cursor, y: $0.y + shelf.top) }
            shelves[index].cursor += pocket.size.width + pocketGap
            shelves[index].height = max(shelf.height, pocket.size.height)
            result.append(pocket)
        }
        return result
    }

    /// Keeps the tidied board where the author was already looking, so the
    /// canvas does not jump out from under them.
    private static func anchored(
        _ positions: [UUID: CanvasPoint], to nodes: [StudioNode], card: (UUID) -> LayeredFlowLayout.Card
    ) -> [UUID: CanvasPoint] {
        let drawn = nodes.reduce(into: CGRect.null) { $0 = $0.union(frame(of: $1.id, at: $1.position, card: card)) }
        let laid = nodes.reduce(into: CGRect.null) { rect, node in
            guard let position = positions[node.id] else { return }
            rect = rect.union(frame(of: node.id, at: position, card: card))
        }
        guard !drawn.isNull, !laid.isNull else { return positions }
        let dx = drawn.minX - laid.minX, dy = drawn.minY - laid.minY
        return positions.mapValues { .init(x: $0.x + dx, y: $0.y + dy) }
    }
}
