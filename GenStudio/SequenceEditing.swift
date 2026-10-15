import Foundation

/// Graph edits for sequence frames and clip slots. Identities are never reassigned, so edges stay on their original image or clip.
enum SequenceEditing {
    static func nextLabel(_ anchors: [ShotAnchor]) -> String {
        let used = Set(anchors.map(\.label)); var ordinal = anchors.count + 1
        while used.contains("Frame \(ordinal)") { ordinal += 1 }
        return "Frame \(ordinal)"
    }
    static func nextClipLabel(_ slots: [DynamicInputPort]) -> String {
        let used = Set(slots.map(\.label)); var ordinal = slots.count + 1
        while used.contains("Clip \(ordinal)") { ordinal += 1 }
        return "Clip \(ordinal)"
    }

    private static func index(_ project: WorkflowProject, _ nodeID: UUID, kind: NodeKind) -> Int? {
        project.nodes.firstIndex { $0.id == nodeID && $0.kind == kind }
    }

    static func addAnchors(_ project: inout WorkflowProject, nodeID: UUID, imagePaths: [String?]) {
        guard let i = index(project, nodeID, kind: .shotSequence) else { return }
        for path in imagePaths where project.nodes[i].sequence.anchors.count < ShotSequenceSpec.maximumAnchors {
            project.nodes[i].sequence.anchors.append(ShotAnchor(label: nextLabel(project.nodes[i].sequence.anchors), imagePath: path))
        }
    }

    static func removeAnchor(_ project: inout WorkflowProject, nodeID: UUID, anchorID: String) {
        guard let i = index(project, nodeID, kind: .shotSequence) else { return }
        project.nodes[i].sequence.anchors.removeAll { $0.id == anchorID }
        project.edges.removeAll { $0.targetID == nodeID && $0.targetPortID == anchorID }
    }

    static func moveAnchor(_ project: inout WorkflowProject, nodeID: UUID, anchorID: String, by offset: Int) {
        guard let i = index(project, nodeID, kind: .shotSequence), let from = project.nodes[i].sequence.anchors.firstIndex(where: { $0.id == anchorID }) else { return }
        let to = from + offset
        guard project.nodes[i].sequence.anchors.indices.contains(to) else { return }
        project.nodes[i].sequence.anchors.swapAt(from, to)
    }

    static func updateAnchor(_ project: inout WorkflowProject, nodeID: UUID, anchorID: String, _ change: (inout ShotAnchor) -> Void) {
        guard let i = index(project, nodeID, kind: .shotSequence), let a = project.nodes[i].sequence.anchors.firstIndex(where: { $0.id == anchorID }) else { return }
        change(&project.nodes[i].sequence.anchors[a])
    }

    static func moveClip(_ project: inout WorkflowProject, nodeID: UUID, portID: String, by offset: Int) {
        guard let i = index(project, nodeID, kind: .assembleVideo), let from = project.nodes[i].dynamicInputs.firstIndex(where: { $0.id == portID }) else { return }
        let to = from + offset
        guard project.nodes[i].dynamicInputs.indices.contains(to) else { return }
        project.nodes[i].dynamicInputs.swapAt(from, to)
    }

    /// Orders a Stitcher's clip slots by where their source nodes sit on the canvas: left to right, and top to bottom
    /// within a column. Sources less than a card-width apart horizontally count as one column. Empty slots go last.
    static func orderClipsByCanvasPosition(_ project: inout WorkflowProject, nodeID: UUID) {
        guard let i = index(project, nodeID, kind: .assembleVideo) else { return }
        let positions = Dictionary(project.nodes.map { ($0.id, $0.position) }, uniquingKeysWith: { a, _ in a })
        func source(_ slot: DynamicInputPort) -> CanvasPoint? {
            project.edges.first { $0.targetID == nodeID && $0.targetPortID == slot.id }.flatMap { positions[$0.sourceID] }
        }
        let slots = project.nodes[i].dynamicInputs
        let connected = slots.compactMap { slot in source(slot).map { (slot, $0) } }
        // Group into columns by x, then read each column top to bottom.
        var columns: [[(DynamicInputPort, CanvasPoint)]] = []
        for entry in connected.sorted(by: { $0.1.x < $1.1.x }) {
            if let anchor = columns.last?.first?.1.x, entry.1.x - anchor < columnTolerance { columns[columns.count - 1].append(entry) }
            else { columns.append([entry]) }
        }
        let ordered = columns.flatMap { $0.sorted { $0.1.y < $1.1.y }.map(\.0) }
        let empty = slots.filter { slot in !ordered.contains { $0.id == slot.id } }
        project.nodes[i].dynamicInputs = ordered + empty
    }
    static let columnTolerance = 120.0

    /// Removes a Stitcher's unconnected clip slots, keeping at least one, and the edits that belonged to them.
    static func removeEmptyClipSlots(_ project: inout WorkflowProject, nodeID: UUID) {
        guard let i = index(project, nodeID, kind: .assembleVideo) else { return }
        let connected = Set(project.edges.filter { $0.targetID == nodeID }.map(\.targetPortID))
        let kept = project.nodes[i].dynamicInputs.filter { connected.contains($0.id) }
        project.nodes[i].dynamicInputs = kept.isEmpty ? Array(project.nodes[i].dynamicInputs.prefix(1)) : kept
        var settings = project.nodes[i].assembly
        settings.clipEdits = settings.clipEdits.filter { key, _ in project.nodes[i].dynamicInputs.contains { $0.id == key } }
        project.nodes[i].assembly = settings
    }

    static func updateClipEdit(_ project: inout WorkflowProject, nodeID: UUID, portID: String, _ change: (inout StitchClipEdit) -> Void) {
        guard let i = index(project, nodeID, kind: .assembleVideo), project.nodes[i].dynamicInputs.contains(where: { $0.id == portID }) else { return }
        var settings = project.nodes[i].assembly
        var edit = settings.edit(for: portID)
        change(&edit)
        edit.trimStart = max(0, edit.trimStart); edit.trimEnd = max(0, edit.trimEnd); edit.volume = min(1, max(0, edit.volume))
        settings.clipEdits[portID] = edit.isDefault ? nil : edit
        project.nodes[i].assembly = settings
    }
}

enum StaleResultPolicy {
    /// Nodes that did not complete in a failed or cancelled run must not keep displaying an older result as current.
    static func unfinishedNodes(_ progress: WorkflowProgress) -> Set<UUID> {
        Set(progress.nodes.filter { $0.value.status != .completed }.map(\.key))
    }
}

extension StudioModel {
    func addSequenceFrames(nodeID: UUID, imagePaths: [String?]) { editGraph { SequenceEditing.addAnchors(&$0, nodeID: nodeID, imagePaths: imagePaths) } }
    func removeSequenceFrame(nodeID: UUID, anchorID: String) { editGraph { SequenceEditing.removeAnchor(&$0, nodeID: nodeID, anchorID: anchorID) } }
    func moveSequenceFrame(nodeID: UUID, anchorID: String, by offset: Int) { editGraph { SequenceEditing.moveAnchor(&$0, nodeID: nodeID, anchorID: anchorID, by: offset) } }
    func updateSequenceFrame(nodeID: UUID, anchorID: String, _ change: (inout ShotAnchor) -> Void) { editGraph { SequenceEditing.updateAnchor(&$0, nodeID: nodeID, anchorID: anchorID, change) } }
    func moveClip(nodeID: UUID, portID: String, by offset: Int) { editGraph { SequenceEditing.moveClip(&$0, nodeID: nodeID, portID: portID, by: offset) } }
    func orderClipsByCanvasPosition(nodeID: UUID) { editGraph { SequenceEditing.orderClipsByCanvasPosition(&$0, nodeID: nodeID) } }
    func removeEmptyClipSlots(nodeID: UUID) { editGraph { SequenceEditing.removeEmptyClipSlots(&$0, nodeID: nodeID) } }
    func updateClipEdit(nodeID: UUID, portID: String, _ change: @escaping (inout StitchClipEdit) -> Void) {
        mutateProjectFromBinding { SequenceEditing.updateClipEdit(&$0, nodeID: nodeID, portID: portID, change) }
    }
    func updateNode(_ nodeID: UUID, _ change: (inout StudioNode) -> Void) {
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            change(&project.nodes[index])
        }
    }

    func updateNodeFromBinding(_ nodeID: UUID, _ change: @escaping (inout StudioNode) -> Void) {
        mutateProjectFromBinding { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            change(&project.nodes[index])
        }
    }
}
