import Foundation

/// A layered (Sugiyama-style) layout for one pocket of the workflow graph.
///
/// The engine deliberately knows nothing about `StudioNode`: it takes ids,
/// wires and measured cards, so the geometry can be reasoned about — and
/// tested — on its own, and the canvas stays the single authority on what a
/// card measures.
///
/// The phases follow the classic pipeline — break cycles, assign layers,
/// reduce crossings, place coordinates — with two departures that matter for a
/// generation graph:
///
/// 1. Layers are *tightened rightwards*. Longest-path layering strands every
///    Prompt in column zero, metres away from the generator it feeds. Pulling
///    each node to sit immediately left of its earliest consumer is what keeps
///    an input beside its node instead of at the far end of a long wire.
/// 2. Each column's vertical placement is solved exactly rather than stacked
///    into row slots shared across the whole graph. A shared rhythm means one
///    tall image card dictates the gaps in every other column; solving per
///    column is what lets a chain run dead straight and stay tight.
struct LayeredFlowLayout {
    struct Wire: Hashable {
        var source: UUID
        var target: UUID
        init(source: UUID, target: UUID) { self.source = source; self.target = target }
    }

    /// A measured card. `leading`/`trailing` are the socket rails, which carry
    /// the port labels outside the card body and must not collide across
    /// columns.
    struct Card: Hashable {
        var width: Double
        var height: Double
        var leading: Double
        var trailing: Double
        init(width: Double, height: Double, leading: Double = 0, trailing: Double = 0) {
            self.width = width; self.height = height; self.leading = leading; self.trailing = trailing
        }
    }

    /// Clearance between the socket rail of one column and the next.
    var columnGap = 56.0
    /// Clearance between two cards stacked in the same column.
    var rowGap = 40.0
    /// Vertical room kept clear where a wire has to travel past a column.
    var channel = 28.0
    var crossingSweeps = 6
    var placementSweeps = 10

    /// A real card, or a bend: the point where a wire that spans more than one
    /// column passes through the columns in between. Bends are laid out like
    /// nodes so long wires get their own channel instead of crossing cards.
    private enum Slot: Hashable {
        case node(UUID)
        case bend(wire: Int, column: Int)
    }

    /// Positions are returned with the pocket's frame origin at (0, 0).
    func positions(ids: [UUID], wires: [Wire], card: (UUID) -> Card, authored: (UUID) -> CanvasPoint) -> [UUID: CanvasPoint] {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [:] }
        let anchor = Dictionary(uniqueKeysWithValues: unique.map { ($0, authored($0)) })
        let ordered = unique.sorted { Self.before($0, $1, anchor) }
        let present = Set(unique)
        let clean = Set(wires.filter { present.contains($0.source) && present.contains($0.target) && $0.source != $0.target })
        let forward = Self.acyclic(ordered, clean, anchor)
        let column = Self.columns(ordered, forward)
        let (grid, after, before) = slots(ordered, forward, column: column, anchor: anchor)
        let arranged = Self.reduceCrossings(grid, after: after, before: before, sweeps: crossingSweeps)
        let cards = Dictionary(uniqueKeysWithValues: unique.map { ($0, card($0)) })
        let y = place(arranged, after: after, before: before, cards: cards)
        let x = columnOrigins(arranged, cards: cards)
        var result: [UUID: CanvasPoint] = [:]
        for (index, layer) in arranged.enumerated() {
            for slot in layer {
                guard case .node(let id) = slot else { continue }
                result[id] = .init(x: x[index], y: y[slot] ?? 0)
            }
        }
        let minX = result.map { $0.value.x - (cards[$0.key]?.leading ?? 0) }.min() ?? 0
        let minY = result.map(\.value.y).min() ?? 0
        return result.mapValues { .init(x: $0.x - minX, y: $0.y - minY) }
    }

    // MARK: - Topology

    /// Authored position breaks every tie, so the order the author drew their
    /// flows in survives a tidy even though their coordinates do not.
    private static func before(_ lhs: UUID, _ rhs: UUID, _ anchor: [UUID: CanvasPoint]) -> Bool {
        let a = anchor[lhs] ?? .init(x: 0, y: 0), b = anchor[rhs] ?? .init(x: 0, y: 0)
        if a.y != b.y { return a.y < b.y }
        if a.x != b.x { return a.x < b.x }
        return lhs.uuidString < rhs.uuidString
    }

    /// Drops back edges found by depth-first search. Layering needs a DAG, and
    /// a cycle is a drawing problem rather than a graph the author can run:
    /// dropping the edge only removes it from the layout's reasoning, never
    /// from the project.
    private static func acyclic(_ ordered: [UUID], _ wires: Set<Wire>, _ anchor: [UUID: CanvasPoint]) -> [Wire] {
        var out: [UUID: [UUID]] = [:]
        for wire in wires { out[wire.source, default: []].append(wire.target) }
        for id in out.keys { out[id]?.sort { before($0, $1, anchor) } }
        enum Mark { case open, closed }
        var mark: [UUID: Mark] = [:]
        var kept: Set<Wire> = []
        for root in ordered where mark[root] == nil {
            mark[root] = .open
            var stack: [(id: UUID, next: Int)] = [(root, 0)]
            while let top = stack.last {
                let children = out[top.id] ?? []
                guard top.next < children.count else {
                    mark[top.id] = .closed
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let child = children[top.next]
                switch mark[child] {
                case .open:
                    continue // A back edge. Leave it out of the layering.
                case .closed:
                    kept.insert(.init(source: top.id, target: child))
                case nil:
                    kept.insert(.init(source: top.id, target: child))
                    mark[child] = .open
                    stack.append((child, 0))
                }
            }
        }
        return kept.sorted {
            $0.source == $1.source ? $0.target.uuidString < $1.target.uuidString : $0.source.uuidString < $1.source.uuidString
        }
    }

    /// Longest-path layering, then tightened rightwards so every node sits
    /// immediately left of its earliest consumer. Without the second pass a
    /// Prompt that feeds a late generator is stranded in column zero and the
    /// board stretches to cover the wire.
    private static func columns(_ ordered: [UUID], _ wires: [Wire]) -> [UUID: Int] {
        var successors = Dictionary(uniqueKeysWithValues: ordered.map { ($0, [UUID]()) })
        var indegree = Dictionary(uniqueKeysWithValues: ordered.map { ($0, 0) })
        for wire in wires {
            successors[wire.source]?.append(wire.target)
            indegree[wire.target, default: 0] += 1
        }
        var queue = ordered.filter { indegree[$0] == 0 }
        var cursor = 0
        var topological: [UUID] = []
        topological.reserveCapacity(ordered.count)
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            topological.append(id)
            for child in successors[id] ?? [] {
                indegree[child, default: 0] -= 1
                if indegree[child] == 0 { queue.append(child) }
            }
        }
        var column = Dictionary(uniqueKeysWithValues: ordered.map { ($0, 0) })
        for id in topological {
            for child in successors[id] ?? [] { column[child] = max(column[child] ?? 0, (column[id] ?? 0) + 1) }
        }
        for id in topological.reversed() {
            if let earliest = (successors[id] ?? []).compactMap({ column[$0] }).min() { column[id] = earliest - 1 }
        }
        return column
    }

    /// Builds the per-column slot lists, inserting a bend for every column a
    /// long wire has to cross, and the slot-level adjacency the ordering and
    /// placement passes work on.
    private func slots(
        _ ordered: [UUID], _ wires: [Wire], column: [UUID: Int], anchor: [UUID: CanvasPoint]
    ) -> (grid: [[Slot]], after: [Slot: [Slot]], before: [Slot: [Slot]]) {
        let count = (column.values.max() ?? 0) + 1
        var grid = [[Slot]](repeating: [], count: count)
        var after: [Slot: [Slot]] = [:]
        var before: [Slot: [Slot]] = [:]
        var seed: [Slot: Double] = [:]
        for id in ordered {
            let slot = Slot.node(id)
            grid[column[id] ?? 0].append(slot)
            seed[slot] = anchor[id]?.y ?? 0
        }
        for (index, wire) in wires.enumerated() {
            let start = column[wire.source] ?? 0, end = column[wire.target] ?? 0
            var path: [Slot] = [.node(wire.source)]
            if end - start > 1 {
                let from = anchor[wire.source]?.y ?? 0, to = anchor[wire.target]?.y ?? 0
                for step in (start + 1)..<end {
                    let bend = Slot.bend(wire: index, column: step)
                    grid[step].append(bend)
                    seed[bend] = from + (to - from) * Double(step - start) / Double(end - start)
                    path.append(bend)
                }
            }
            path.append(.node(wire.target))
            for step in 0..<(path.count - 1) {
                after[path[step], default: []].append(path[step + 1])
                before[path[step + 1], default: []].append(path[step])
            }
        }
        for index in grid.indices {
            grid[index].sort {
                let a = seed[$0] ?? 0, b = seed[$1] ?? 0
                return a == b ? Self.describe($0) < Self.describe($1) : a < b
            }
        }
        return (grid, after, before)
    }

    private static func describe(_ slot: Slot) -> String {
        switch slot {
        case .node(let id): "n\(id.uuidString)"
        case .bend(let wire, let column): "b\(wire)-\(column)"
        }
    }

    // MARK: - Crossing reduction

    /// Barycentre sweeps with adjacent-exchange refinement, keeping the best
    /// arrangement seen. Both passes are order-stable, so a tidied graph fed
    /// back in reproduces itself.
    private static func reduceCrossings(
        _ grid: [[Slot]], after: [Slot: [Slot]], before: [Slot: [Slot]], sweeps: Int
    ) -> [[Slot]] {
        guard grid.count > 1 else { return grid }
        var current = grid
        var best = grid
        var fewest = crossings(grid, after: after)
        for sweep in 0..<sweeps {
            if sweep.isMultiple(of: 2) {
                for index in 1..<current.count {
                    current[index] = barycentre(current[index], reference: current[index - 1], neighbours: before)
                }
            } else {
                for index in stride(from: current.count - 2, through: 0, by: -1) {
                    current[index] = barycentre(current[index], reference: current[index + 1], neighbours: after)
                }
            }
            exchange(&current, after: after, before: before)
            let total = crossings(current, after: after)
            if total < fewest { fewest = total; best = current }
        }
        return best
    }

    /// Sorts a column by the mean position of its neighbours in the reference
    /// column. A slot with no neighbour there keeps its place rather than
    /// collapsing to one end.
    private static func barycentre(_ layer: [Slot], reference: [Slot], neighbours: [Slot: [Slot]]) -> [Slot] {
        let index = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, Double($0)) })
        let weights = layer.enumerated().map { position, slot -> (Slot, Double, Int) in
            let related = (neighbours[slot] ?? []).compactMap { index[$0] }
            let value = related.isEmpty ? Double(position) : related.reduce(0, +) / Double(related.count)
            return (slot, value, position)
        }
        return weights.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.map(\.0)
    }

    private static func exchange(_ grid: inout [[Slot]], after: [Slot: [Slot]], before: [Slot: [Slot]]) {
        var improved = true
        var rounds = 0
        while improved && rounds < 8 {
            improved = false
            rounds += 1
            for index in grid.indices {
                guard grid[index].count > 1 else { continue }
                let upper = index > 0 ? positionMap(grid[index - 1]) : [:]
                let lower = index < grid.count - 1 ? positionMap(grid[index + 1]) : [:]
                for position in 0..<(grid[index].count - 1) {
                    let left = grid[index][position], right = grid[index][position + 1]
                    let keep = pairCrossings(left, right, after: after, before: before, upper: upper, lower: lower)
                    let swap = pairCrossings(right, left, after: after, before: before, upper: upper, lower: lower)
                    if swap < keep {
                        grid[index].swapAt(position, position + 1)
                        improved = true
                    }
                }
            }
        }
    }

    private static func positionMap(_ layer: [Slot]) -> [Slot: Int] {
        Dictionary(uniqueKeysWithValues: layer.enumerated().map { ($1, $0) })
    }

    /// Crossings contributed by `first` sitting directly above `second`.
    private static func pairCrossings(
        _ first: Slot, _ second: Slot, after: [Slot: [Slot]], before: [Slot: [Slot]],
        upper: [Slot: Int], lower: [Slot: Int]
    ) -> Int {
        var total = 0
        for (neighbours, index) in [(after, lower), (before, upper)] where !index.isEmpty {
            let left = (neighbours[first] ?? []).compactMap { index[$0] }
            let right = (neighbours[second] ?? []).compactMap { index[$0] }
            for a in left { for b in right where b < a { total += 1 } }
        }
        return total
    }

    private static func crossings(_ grid: [[Slot]], after: [Slot: [Slot]]) -> Int {
        var total = 0
        guard grid.count > 1 else { return 0 }
        for index in 0..<(grid.count - 1) {
            let upper = positionMap(grid[index]), lower = positionMap(grid[index + 1])
            var pairs: [(Int, Int)] = []
            for slot in grid[index] {
                guard let from = upper[slot] else { continue }
                for child in after[slot] ?? [] { if let to = lower[child] { pairs.append((from, to)) } }
            }
            guard pairs.count > 1 else { continue }
            for a in 0..<(pairs.count - 1) {
                for b in (a + 1)..<pairs.count where (pairs[a].0 - pairs[b].0) * (pairs[a].1 - pairs[b].1) < 0 { total += 1 }
            }
        }
        return total
    }

    // MARK: - Coordinates

    /// Cards are aligned on their top edge, which is how the author draws rows
    /// and what keeps a chain reading as one lane across the board.
    private func place(
        _ grid: [[Slot]], after: [Slot: [Slot]], before: [Slot: [Slot]], cards: [UUID: Card]
    ) -> [Slot: Double] {
        let height: (Slot) -> Double = { slot in
            guard case .node(let id) = slot else { return 0 }
            return cards[id]?.height ?? 0
        }
        let isBend: (Slot) -> Bool = { if case .bend = $0 { return true } else { return false } }
        var separations: [[Double]] = []
        for layer in grid {
            var gaps: [Double] = []
            for index in 0..<max(layer.count - 1, 0) {
                let bendInvolved = isBend(layer[index]) || isBend(layer[index + 1])
                gaps.append(height(layer[index]) + (bendInvolved ? channel : rowGap))
            }
            separations.append(gaps)
        }
        var y: [Slot: Double] = [:]
        for (index, layer) in grid.enumerated() {
            var cursor = 0.0
            for (position, slot) in layer.enumerated() {
                y[slot] = cursor
                if position < separations[index].count { cursor += separations[index][position] }
            }
        }
        for sweep in 0..<placementSweeps {
            let sequence = sweep.isMultiple(of: 2) ? Array(grid.indices) : Array(grid.indices.reversed())
            for index in sequence {
                let layer = grid[index]
                guard !layer.isEmpty else { continue }
                var desired: [Double] = [], weights: [Double] = []
                for slot in layer {
                    let related = (after[slot] ?? []) + (before[slot] ?? [])
                    let values = related.compactMap { y[$0] }
                    desired.append(values.isEmpty ? (y[slot] ?? 0) : values.reduce(0, +) / Double(values.count))
                    // A bend outranks a card: a long wire that bows around a
                    // card reads far worse than a card sitting a few points
                    // off its ideal row.
                    weights.append(isBend(slot) ? 6 : (values.isEmpty ? 0.05 : 1))
                }
                let settled = Self.settle(desired: desired, weights: weights, separations: separations[index])
                for (position, slot) in layer.enumerated() { y[slot] = settled[position] }
            }
        }
        return y
    }

    /// Places one column so every card keeps its minimum separation while
    /// sitting as close as possible to where its wires want it.
    ///
    /// Shifting by the running separation turns the problem into isotonic
    /// regression, which pool-adjacent-violators solves exactly in one pass.
    /// An exact answer is what makes a chain dead straight; nudging heuristics
    /// leave it almost-aligned, which reads as sloppier than either extreme.
    static func settle(desired: [Double], weights: [Double], separations: [Double]) -> [Double] {
        let count = desired.count
        guard count > 0 else { return [] }
        var offsets = [Double](repeating: 0, count: count)
        for index in 1..<max(count, 1) { offsets[index] = offsets[index - 1] + (separations.indices.contains(index - 1) ? separations[index - 1] : 0) }
        var values: [Double] = [], mass: [Double] = [], spans: [Int] = []
        for index in 0..<count {
            var value = desired[index] - offsets[index]
            var weight = max(weights.indices.contains(index) ? weights[index] : 1, 0.0001)
            var span = 1
            while let last = values.last, last > value + 1e-9 {
                let previousWeight = mass.removeLast(), previousValue = values.removeLast(), previousSpan = spans.removeLast()
                value = (previousValue * previousWeight + value * weight) / (previousWeight + weight)
                weight += previousWeight
                span += previousSpan
            }
            values.append(value); mass.append(weight); spans.append(span)
        }
        var flattened: [Double] = []
        flattened.reserveCapacity(count)
        for (index, value) in values.enumerated() { flattened.append(contentsOf: repeatElement(value, count: spans[index])) }
        return (0..<count).map { flattened[$0] + offsets[$0] }
    }

    /// Columns are spaced so the socket rail of one never reaches the rail of
    /// the next, and no further.
    private func columnOrigins(_ grid: [[Slot]], cards: [UUID: Card]) -> [Double] {
        let measure: ([Slot], (Card) -> Double) -> Double = { layer, value in
            layer.compactMap { slot -> Double? in
                guard case .node(let id) = slot, let card = cards[id] else { return nil }
                return value(card)
            }.max() ?? 0
        }
        var origins = [Double](repeating: 0, count: grid.count)
        for index in 1..<max(grid.count, 1) {
            let right = measure(grid[index - 1]) { $0.width + $0.trailing }
            let left = measure(grid[index]) { $0.leading }
            origins[index] = origins[index - 1] + right + columnGap + left
        }
        return origins
    }
}
