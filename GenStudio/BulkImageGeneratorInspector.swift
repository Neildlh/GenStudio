import SwiftUI

/// Bulk edits for several Image Generator nodes selected together. Each node keeps its own
/// settings; these actions just write the same model or aspect ratio to every one of them.
extension StudioModel {
    /// The Image Generator nodes in `ids`, or an empty list unless the selection is only Image Generators.
    func bulkImageGenerators(_ ids: Set<UUID>) -> [StudioNode] {
        guard ids.count > 1, let project = currentProject else { return [] }
        let nodes = project.nodes.filter { ids.contains($0.id) }
        return nodes.count == ids.count && nodes.allSatisfy({ $0.kind == .imageGenerator }) ? nodes : []
    }

    private func referenceCount(of node: StudioNode, in project: WorkflowProject) -> Int {
        project.edges.filter { $0.targetID == node.id && node.imageGeneratorReferencePortIDs.contains($0.targetPortID) }.count
    }

    /// Recipe IDs that every selected node can run, given its own connected references.
    func commonImageRecipeIDs(for nodes: [StudioNode]) -> [String] {
        guard let project = currentProject else { return [] }
        let perNode = nodes.map { node -> [String] in
            let count = referenceCount(of: node, in: project)
            return ImageCapabilityRegistry.selectableCapabilities(task: ImageCapabilityRegistry.task(referenceCount: count), referenceCount: count, installed: libraryStore.installed).map(\.recipeID)
        }
        guard var common = perNode.first else { return [] }
        for ids in perNode.dropFirst() { common = common.filter(ids.contains) }
        return common
    }

    func setImageModel(_ recipeID: String, for ids: Set<UUID>) {
        editGraph { project in
            for index in project.nodes.indices where ids.contains(project.nodes[index].id) && project.nodes[index].kind == .imageGenerator {
                project.nodes[index].model = recipeID
                project.nodes[index].experimentalImageRecipeID = recipeID.isEmpty ? nil : recipeID
            }
        }
    }

    func setAspectRatio(_ preset: AspectRatioPreset, for ids: Set<UUID>) {
        let installed = libraryStore.installed
        editGraph { project in
            for index in project.nodes.indices where ids.contains(project.nodes[index].id) && project.nodes[index].kind == .imageGenerator {
                let node = project.nodes[index]
                let task = ImageCapabilityRegistry.task(referenceCount: referenceCount(of: node, in: project))
                guard let capability = ImageCapabilityRegistry.capability(recipeID: node.model, task: task)
                        ?? installed.first(where: { $0.id == node.model })?.recipeSnapshot.flatMap({ ImageCapabilityRegistry.userCapability(recipe: $0, task: task) }),
                      let size = preset.dimensions(width: capability.width, height: capability.height, targetPixels: capability.optimalPixels) else { continue }
                project.nodes[index].width = size.0
                project.nodes[index].height = size.1
                VideoDimensionSync.resyncTargets(of: node.id, in: &project)
            }
        }
    }
}

struct BulkImageGeneratorInspector: View {
    @ObservedObject var model: StudioModel
    let nodes: [StudioNode]

    private var ids: Set<UUID> { Set(nodes.map(\.id)) }
    /// Live values, so the pickers reflect edits as they land.
    private var live: [StudioNode] {
        let current = model.currentProject?.nodes ?? []
        return nodes.compactMap { node in current.first { $0.id == node.id } }
    }

    var body: some View {
        let choices = model.commonImageRecipeIDs(for: nodes)
        let models = Set(live.map(\.model))
        let sizes = Set(live.map { "\($0.width)x\($0.height)" })
        Section("\(nodes.count) Image Generators") {
            Text("Changes here apply to every selected node. Each node keeps its own prompt, seed and inputs.").font(.caption).foregroundStyle(.secondary)
            Picker("Model", selection: Binding(
                get: { models.count == 1 ? (models.first ?? "") : "__mixed__" },
                set: { if $0 != "__mixed__" { model.setImageModel($0, for: ids) } }
            )) {
                if models.count > 1 { Text("Mixed").tag("__mixed__") }
                Text("Choose an installed model").tag("")
                ForEach(choices, id: \.self) { id in
                    Text((ModelCatalog.recipes.first { $0.id == id }.map(ModelRecipePresentation.title) ?? model.modelName(id)) + ModelAdvisor.pickerNote(id)).tag(id)
                }
            }
            .disabled(choices.isEmpty)
            if models.count == 1, let id = models.first { FinalQualityBadge(recipeID: id) }
            if choices.isEmpty {
                Text("No installed model can run all of these nodes. Nodes with connected references need an image-to-image model.").font(.caption).foregroundStyle(.orange)
            }
            if let first = live.first, sizes.count == 1 {
                AspectRatioPicker(currentWidth: first.width, currentHeight: first.height) { model.setAspectRatio($0, for: ids) }
            } else if let first = live.first {
                AspectRatioPicker(currentWidth: 0, currentHeight: first.height) { model.setAspectRatio($0, for: ids) }
                Text("Nodes currently use different sizes. Choosing a ratio sets them all.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
