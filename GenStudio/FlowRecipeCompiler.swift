import Foundation

/// Turns an author-friendly recipe into a full workflow. Every problem is collected, not just the first,
/// so an AI (or a person) can fix a recipe in one pass.
struct FlowRecipeCompiler {
    /// Builds a fresh node. The app passes its own factory so models and video defaults match a hand-added node;
    /// the default is a bare node, which leaves models blank.
    var makeNode: (NodeKind) -> StudioNode = { StudioNode(kind: $0, label: $0.title, position: .init(x: 0, y: 0)) }

    func compile(_ recipe: FlowRecipe) -> FlowCompileResult {
        var issues: [FlowIssue] = []
        func error(_ path: String, _ message: String) { issues.append(.init(severity: .error, path: path, message: message)) }
        func warn(_ path: String, _ message: String) { issues.append(.init(severity: .warning, path: path, message: message)) }

        if let format = recipe.format, format != FlowRecipe.formatName { error("format", "must be \"\(FlowRecipe.formatName)\" (found \"\(format)\").") }
        if let version = recipe.version, version != FlowRecipe.currentVersion { error("version", "this GenStudio reads recipe version \(FlowRecipe.currentVersion) (found \(version)).") }
        if recipe.nodes.isEmpty { error("nodes", "a flow needs at least one node.") }

        // Nodes
        var built: [String: StudioNode] = [:]
        var order: [String] = []
        for (index, spec) in recipe.nodes.enumerated() {
            let path = "nodes[\(index)]"
            guard FlowNaming.isValidNodeID(spec.id) else { error("\(path).id", "'\(spec.id)' is not a valid id. Use letters, digits, '-' or '_' only, for example \"hero\"."); continue }
            guard built[spec.id] == nil else { error("\(path).id", "the id '\(spec.id)' is used twice. Every node needs its own id."); continue }
            guard let kind = Self.kind(named: spec.kind) else { error("\(path).kind", Self.unknownKindMessage(spec.kind)); continue }
            var node = makeNode(kind)
            node.id = UUID()
            node.label = spec.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? kind.title
            issues += applyInputs(spec, kind: kind, to: &node, path: path)
            issues += applySettings(spec, kind: kind, to: &node, path: path)
            built[spec.id] = node
            order.append(spec.id)
        }

        // Wires
        var edges: [StudioEdge] = []
        var occupied: Set<PortAddress> = []
        for (index, wire) in recipe.wires.enumerated() {
            let path = "wires[\(index)]"
            switch resolveWire(wire, nodes: built, occupied: occupied) {
            case .failure(let failure): error(path, failure.message)
            case .success(let edge):
                occupied.insert(.init(nodeID: edge.targetID, portID: edge.targetPortID))
                edges.append(edge)
            }
        }

        guard issues.allSatisfy({ $0.severity != .error }) else { return .init(project: nil, issues: issues) }
        var nodes = order.compactMap { built[$0] }

        // Author-facing notes that never block an import.
        for (id, node) in zip(order, nodes) {
            let path = "node '\(id)'"
            if node.kind.usesModel, node.model.isEmpty { warn(path, "\(node.label) has no model yet. Install a compatible model in the Model Library, then choose it in the node's settings.") }
            if node.kind == .imageInput || node.kind == .videoInput || node.kind == .maskInput { warn(path, "\(node.label) needs a file. Select the node and choose one from your Mac.") }
            if node.kind == .prompt, node.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warn(path, "\(node.label) has no text yet.") }
            if node.kind == .imagePrompt, node.imagePromptSettings?.compiledPrompt.isEmpty ?? true { warn(path, "\(node.label) needs a subject before it produces a prompt.") }
            if node.kind == .videoPrompt, node.videoPromptSettings?.compiledPrompt.isEmpty ?? true { warn(path, "\(node.label) needs an action before it produces a prompt.") }
            if node.kind == .promptTemplate {
                let used = Set(PromptTemplateSyntax.variables(in: node.prompt)), declared = Set(node.dynamicInputs.map(\.label))
                if !used.subtracting(declared).isEmpty { warn(path, "\(node.label) uses {{\(used.subtracting(declared).sorted().joined(separator: "}}, {{"))}} in its text but has no input with that name.") }
            }
            let connected = Set(edges.filter { $0.targetID == node.id }.map(\.targetPortID))
            for port in node.inputPorts where port.required && !connected.contains(port.id) && node.kind != .stickyNote {
                warn(path, "\(node.label) has nothing wired into its \(port.label) input, so it cannot run yet.")
            }
        }

        // Layout, then the app's own structural validator (cycles, duplicate connections, port contracts).
        let layout = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        for index in nodes.indices { if let point = layout[nodes[index].id] { nodes[index].position = point } }
        let name = recipe.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Imported Flow"
        var project = WorkflowProject(name: name, nodes: nodes, edges: edges)
        // Recipes do not carry canvas state. Focus the imported workflow on its
        // first authored production node instead of opening at an arbitrary
        // empty coordinate in a large auto-laid-out graph.
        if let first = nodes.first(where: { $0.kind != .stickyNote }) ?? nodes.first {
            project.viewport = .init(offset: .init(x: 48 - first.position.x, y: 48 - first.position.y), zoom: 1)
        }
        do { _ = try GraphValidator().validate(project, installedModels: nil, requireRunnableInputs: false) }
        catch { return .init(project: nil, issues: issues + [.init(severity: .error, path: "wires", message: error.localizedDescription)]) }
        return .init(project: project, issues: issues)
    }

    // MARK: Kinds

    static func kind(named name: String) -> NodeKind? {
        NodeKind(rawValue: name) ?? NodeKind.allCases.first { $0.rawValue.lowercased() == name.lowercased() || FlowNaming.slug($0.title) == FlowNaming.slug(name) }
    }
    static func unknownKindMessage(_ name: String) -> String {
        let needle = name.lowercased()
        let close = NodeKind.allCases.filter { $0.rawValue.lowercased().contains(needle) || needle.contains($0.rawValue.lowercased()) || $0.title.lowercased().contains(needle) }.map(\.rawValue)
        let hint = close.isEmpty ? "Valid kinds: \(NodeKind.allCases.map(\.rawValue).joined(separator: ", "))." : "Did you mean \(close.prefix(4).joined(separator: ", "))? Valid kinds: \(NodeKind.allCases.map(\.rawValue).joined(separator: ", "))."
        return "'\(name)' is not a node kind. \(hint)"
    }

    // MARK: Inputs

    private func applyInputs(_ spec: FlowNodeSpec, kind: NodeKind, to node: inout StudioNode, path: String) -> [FlowIssue] {
        guard let labels = spec.inputs else { return [] }
        let declarable = kind.supportsDynamicTextInputs || kind.supportsDynamicImageInputs || kind.supportsDynamicVideoInputs
        guard declarable else {
            return [.init(severity: .error, path: "\(path).inputs", message: "\(kind.rawValue) has fixed inputs; remove `inputs`. Only combineText, promptTemplate, imageDescriber and assembleVideo take a list of inputs.")]
        }
        let cleaned = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var issues: [FlowIssue] = []
        if cleaned.isEmpty || cleaned.contains(where: \.isEmpty) { issues.append(.init(severity: .error, path: "\(path).inputs", message: "give every input a non-empty label, for example [\"Part 1\", \"Part 2\"].")) }
        if Set(cleaned.map(FlowNaming.slug)).count != cleaned.count { issues.append(.init(severity: .error, path: "\(path).inputs", message: "input labels must be different from each other.")) }
        let limit = kind.supportsDynamicVideoInputs ? AssemblySettings.maximumClips : 32
        if cleaned.count > limit { issues.append(.init(severity: .error, path: "\(path).inputs", message: "\(kind.rawValue) accepts at most \(limit) inputs.")) }
        guard issues.isEmpty else { return issues }
        let type: PortDataType = kind.supportsDynamicImageInputs ? .image : kind.supportsDynamicVideoInputs ? .video : .text
        node.dynamicInputs = cleaned.map { .init(id: FlowNaming.slug($0), label: $0, type: type) }
        return []
    }

    // MARK: Settings

    private func applySettings(_ spec: FlowNodeSpec, kind: NodeKind, to node: inout StudioNode, path: String) -> [FlowIssue] {
        guard let supplied = spec.settings, !supplied.isEmpty else { return [] }
        var issues: [FlowIssue] = []
        let valid = FlowSettingCatalog.settings(for: kind)
        for key in supplied.keys.sorted() where !valid.contains(where: { $0.key == key }) {
            let hint = valid.isEmpty ? "\(kind.rawValue) has no settings; remove `settings`." : "Valid settings for \(kind.rawValue): \(valid.map(\.key).joined(separator: ", "))."
            issues.append(.init(severity: .error, path: "\(path).settings.\(key)", message: "'\(key)' is not a setting of \(kind.rawValue). \(hint)"))
        }
        // Catalog order, so dependent settings (fps before durationSeconds) apply deterministically.
        for setting in valid {
            guard let value = supplied[setting.key] else { continue }
            let at = "\(path).settings.\(setting.key)"
            if let problem = Self.check(value, against: setting.type) { issues.append(.init(severity: .error, path: at, message: problem)); continue }
            do { try setting.set(&node, value) }
            catch let failure as FlowSettingError { issues.append(.init(severity: .error, path: at, message: failure.message)) }
            catch { issues.append(.init(severity: .error, path: at, message: error.localizedDescription)) }
        }
        return issues
    }

    static func check(_ value: FlowValue, against type: FlowSetting.ValueType) -> String? {
        switch (type, value) {
        case (.text, .string), (.bool, .bool), (.structured, _): return nil
        case (.integer(let range), .number(let n)):
            guard n == n.rounded() else { return "must be a whole number, not \(FlowNaming.plain(n))." }
            return range.contains(Int(n)) ? nil : "must be between \(range.lowerBound) and \(range.upperBound) (found \(Int(n)))."
        case (.number(let range), .number(let n)):
            return range.contains(n) ? nil : "must be between \(FlowNaming.plain(range.lowerBound)) and \(FlowNaming.plain(range.upperBound)) (found \(FlowNaming.plain(n)))."
        case (.choice(let options), .string(let s)):
            return options.contains(s) ? nil : "'\(s)' is not one of: \(options.map { "\"\($0)\"" }.joined(separator: ", "))."
        default: return "expected \(type.summary), but found \(value.kindName)."
        }
    }

    // MARK: Wires

    private struct WireFailure: Error { let message: String }

    private func resolveWire(_ text: String, nodes: [String: StudioNode], occupied: Set<PortAddress>) -> Result<StudioEdge, WireFailure> {
        let separators = ["->", "→"]
        guard let separator = separators.first(where: { text.contains($0) }) else { return .failure(.init(message: "'\(text)' is not a wire. Write it as \"sourceNode.output -> targetNode.input\".")) }
        let halves = text.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
        guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty else { return .failure(.init(message: "'\(text)' needs exactly one source and one target, like \"sourceNode.output -> targetNode.input\".")) }
        func split(_ endpoint: String) -> (node: String, port: String?) {
            guard let dot = endpoint.firstIndex(of: ".") else { return (endpoint, nil) }
            return (String(endpoint[..<dot]), String(endpoint[endpoint.index(after: dot)...]))
        }
        let (sourceName, sourcePortName) = split(halves[0]), (targetName, targetPortName) = split(halves[1])
        guard let source = nodes[sourceName] else { return .failure(.init(message: "'\(sourceName)' is not a node id. Node ids in this flow: \(nodes.keys.sorted().joined(separator: ", ")).")) }
        guard let target = nodes[targetName] else { return .failure(.init(message: "'\(targetName)' is not a node id. Node ids in this flow: \(nodes.keys.sorted().joined(separator: ", ")).")) }
        guard source.id != target.id else { return .failure(.init(message: "'\(sourceName)' cannot connect to itself.")) }

        let outputs = source.outputPorts
        let output: PortDescriptor
        if let sourcePortName {
            guard let match = Self.port(named: sourcePortName, in: outputs) else {
                return .failure(.init(message: "\(sourceName) (\(source.kind.rawValue)) has no output '\(sourcePortName)'. Its outputs: \(Self.describe(outputs))."))
            }
            output = match
        } else {
            guard outputs.count == 1 else {
                return .failure(.init(message: outputs.isEmpty ? "\(sourceName) (\(source.kind.rawValue)) has no outputs, so nothing can be wired from it." : "\(sourceName) (\(source.kind.rawValue)) has several outputs, so name one: \(Self.describe(outputs))."))
            }
            output = outputs[0]
        }

        let inputs = target.inputPorts
        let input: PortDescriptor
        if let targetPortName {
            guard let match = Self.port(named: targetPortName, in: inputs) else {
                let known = inputs.isEmpty ? "It has no inputs." : "Its inputs: \(Self.describe(inputs))."
                let extra = target.kind.supportsDynamicTextInputs || target.kind.supportsDynamicImageInputs || target.kind.supportsDynamicVideoInputs ? " Declare more sockets with `inputs` on that node." : ""
                return .failure(.init(message: "\(targetName) (\(target.kind.rawValue)) has no input '\(targetPortName)'. \(known)\(extra)"))
            }
            input = match
        } else {
            let candidates = inputs.filter { $0.type == output.type && !occupied.contains(.init(nodeID: target.id, portID: $0.id)) }
            guard candidates.count == 1 else {
                return .failure(.init(message: candidates.isEmpty ? "\(targetName) (\(target.kind.rawValue)) has no free \(output.type.rawValue) input. Its inputs: \(Self.describe(inputs))." : "\(targetName) (\(target.kind.rawValue)) has several \(output.type.rawValue) inputs, so name one: \(candidates.map(\.id).joined(separator: ", "))."))
            }
            input = candidates[0]
        }

        guard output.type == input.type else {
            return .failure(.init(message: "cannot wire \(sourceName).\(output.id) (\(output.type.rawValue)) into \(targetName).\(input.id) (\(input.type.rawValue)). Wires only connect matching types."))
        }
        guard !occupied.contains(.init(nodeID: target.id, portID: input.id)) else {
            return .failure(.init(message: "\(targetName).\(input.id) already has a wire. An input accepts exactly one wire; an output can feed many inputs."))
        }
        return .success(StudioEdge(sourceID: source.id, sourcePortID: output.id, targetID: target.id, targetPortID: input.id, type: output.type))
    }

    private static func port(named name: String, in ports: [PortDescriptor]) -> PortDescriptor? {
        ports.first { $0.id == name } ?? ports.first { $0.label.lowercased() == name.lowercased() } ?? ports.first { FlowNaming.slug($0.label) == FlowNaming.slug(name) }
    }
    static func describe(_ ports: [PortDescriptor]) -> String {
        ports.isEmpty ? "none" : ports.map { "\($0.id) (\($0.type.rawValue)\($0.required ? "" : ", optional"))" }.joined(separator: ", ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Export

enum FlowRecipeExporter {
    /// Only settings that differ from a freshly added node are written, and no model ids or file paths ever are,
    /// so the file is small, readable and safe to share.
    static func recipe(from project: WorkflowProject, makeNode: (NodeKind) -> StudioNode = { StudioNode(kind: $0, label: $0.title, position: .init(x: 0, y: 0)) }) -> FlowRecipe {
        var used: Set<String> = []
        var ids: [UUID: String] = [:]
        for node in project.nodes {
            let base = FlowNaming.slug(node.label)
            var candidate = base, n = 2
            while !used.insert(candidate).inserted { candidate = "\(base)-\(n)"; n += 1 }
            ids[node.id] = candidate
        }
        let specs = project.nodes.map { node -> FlowNodeSpec in
            let baseline = makeNode(node.kind)
            var settings: [String: FlowValue] = [:]
            for setting in FlowSettingCatalog.settings(for: node.kind) {
                let value = setting.get(node)
                if value != setting.get(baseline) { settings[setting.key] = value }
            }
            var inputs: [String]?
            let dynamic = node.kind.supportsDynamicTextInputs || node.kind.supportsDynamicImageInputs || node.kind.supportsDynamicVideoInputs
            if dynamic, node.dynamicInputs.map(\.label) != baseline.dynamicInputs.map(\.label) { inputs = node.dynamicInputs.map(\.label) }
            return FlowNodeSpec(id: ids[node.id] ?? "node", kind: node.kind.rawValue, label: node.label == node.kind.title ? nil : node.label, settings: settings.isEmpty ? nil : settings, inputs: inputs)
        }
        let byID = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        func endpoint(_ id: UUID, _ portID: String, input: Bool) -> String? {
            guard let node = byID[id], let name = ids[id] else { return nil }
            let usesLabels = node.kind.supportsDynamicTextInputs || node.kind.supportsDynamicImageInputs || node.kind.supportsDynamicVideoInputs
            if input, usesLabels, let port = node.inputPorts.first(where: { $0.id == portID }), node.kind != .imageGenerator { return "\(name).\(FlowNaming.slug(port.label))" }
            return "\(name).\(portID)"
        }
        let wires = project.edges.compactMap { edge -> String? in
            guard let from = endpoint(edge.sourceID, edge.sourcePortID, input: false), let to = endpoint(edge.targetID, edge.targetPortID, input: true) else { return nil }
            return "\(from) -> \(to)"
        }
        return FlowRecipe(name: project.name, nodes: specs, wires: wires)
    }

    static func data(_ recipe: FlowRecipe) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(recipe)
    }
}

// MARK: - Reading pasted or saved text

enum FlowDocument {
    case recipe(FlowRecipe)
    case fullProject(WorkflowProject)
}

enum FlowDocumentParser {
    struct ParseFailure: Error { let message: String }

    /// Accepts a recipe or a full backup, tolerating what chat AIs wrap around JSON: code fences and surrounding prose.
    static func parse(_ text: String) -> Result<FlowDocument, ParseFailure> {
        guard let json = extractJSON(from: text) else {
            return .failure(.init(message: "No JSON was found. Paste the complete JSON object the AI produced, starting with { and ending with }."))
        }
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(message: "The text looks like JSON but is not valid JSON (check for a missing comma, quote or bracket, or a comment). Ask the AI to return strictly valid JSON."))
        }
        if object["schemaVersion"] != nil && object["format"] == nil {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            do { return .success(.fullProject(try decoder.decode(WorkflowProject.self, from: data))) }
            catch { return .failure(.init(message: "This looks like a GenStudio backup but could not be read: \(error.localizedDescription)")) }
        }
        do { return .success(.recipe(try JSONDecoder().decode(FlowRecipe.self, from: data))) }
        catch let error as DecodingError { return .failure(.init(message: describe(error))) }
        catch { return .failure(.init(message: error.localizedDescription)) }
    }

    static func extractJSON(from text: String) -> String? {
        var body = text.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = body.range(of: "```") {
            let afterOpen = body[open.upperBound...]
            let contentStart = afterOpen.firstIndex(of: "\n").map { afterOpen.index(after: $0) } ?? afterOpen.startIndex
            if let close = afterOpen.range(of: "```", range: contentStart..<afterOpen.endIndex) { body = String(afterOpen[contentStart..<close.lowerBound]) }
        }
        guard let start = body.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in body[start...].indices {
            let c = body[index]
            if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
            if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { return String(body[start...index]) } }
        }
        return nil
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error {
        case .keyNotFound(let key, let context): return "Missing \"\(key.stringValue)\"\(context.codingPath.isEmpty ? "" : " in \(path(context))"). Every node needs \"id\" and \"kind\"; the flow needs \"nodes\"."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): wrong type. \(context.debugDescription)"
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
