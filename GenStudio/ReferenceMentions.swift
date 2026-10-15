import Foundation

/// A prompt token that names one of an Image Generator's Reference sockets.
/// The token stores the canvas socket number; execution resolves it to the
/// reference's actual run position after empty sockets have been skipped.
struct ReferenceMention: Identifiable, Hashable, Sendable {
    let generatorID: UUID
    let socketNumber: Int
    let runPosition: Int
    let socketLabel: String

    var id: String { "\(generatorID.uuidString)-\(socketNumber)" }
    var token: String { "@reference \(socketNumber)" }
    var detail: String {
        socketNumber == runPosition ? socketLabel : "\(socketLabel) → image \(runPosition)"
    }
}

enum ReferenceMentionCatalog {
    /// Suggestions are intentionally offered only when one prompt directly
    /// feeds one Image Generator. A prompt branched into generators with
    /// different reference inputs has no unambiguous `@reference 1` meaning.
    static func suggestions(forPromptNodeID promptNodeID: UUID, in project: WorkflowProject) -> [ReferenceMention] {
        let targetIDs = Set(project.edges.compactMap { edge -> UUID? in
            guard edge.sourceID == promptNodeID,
                  let target = project.nodes.first(where: { $0.id == edge.targetID }),
                  target.kind == .imageGenerator,
                  edge.targetPortID == "prompt" else { return nil }
            return target.id
        })
        guard targetIDs.count == 1,
              let generatorID = targetIDs.first,
              let generator = project.nodes.first(where: { $0.id == generatorID }) else { return [] }
        let connected = ReferenceRoleComposer.connectedReferencePortIDs(node: generator, edges: project.edges)
        return connected.enumerated().compactMap { runIndex, portID in
            guard let socketIndex = generator.imageGeneratorReferencePortIDs.firstIndex(of: portID),
                  let label = generator.inputPorts.first(where: { $0.id == portID })?.label else { return nil }
            return .init(generatorID: generatorID, socketNumber: socketIndex + 1,
                         runPosition: runIndex + 1, socketLabel: label)
        }
    }

    /// The unfinished @word at the end of the editor text. Keeping completion
    /// to the active suffix means choosing a suggestion never rewrites prose
    /// earlier in a multi-line prompt.
    static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let suffix = text[at...]
        guard !suffix.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(suffix.dropFirst()).lowercased()
    }

    static func matches(_ mention: ReferenceMention, query: String) -> Bool {
        let token = mention.token.dropFirst().lowercased()
        let short = "ref \(mention.socketNumber)"
        return query.isEmpty || token.hasPrefix(query) || short.hasPrefix(query)
    }

    static func inserting(_ mention: ReferenceMention, into text: String) -> String {
        guard let at = text.lastIndex(of: "@"), query(in: text) != nil else { return text }
        return String(text[..<at]) + mention.token + " "
    }

    /// Expands tokens only at the Image Generator execution boundary. The
    /// authored workflow remains readable and reconnecting a socket updates
    /// the reference number the model receives on the next run.
    static func resolve(_ prompt: String, for generator: StudioNode, connectedPortIDs: [String]) throws -> String {
        let expression = try NSRegularExpression(pattern: #"(?i)@reference\s+([1-9][0-9]*)\b"#)
        let range = NSRange(prompt.startIndex..., in: prompt)
        let matches = expression.matches(in: prompt, range: range)
        var resolved = prompt
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: prompt),
                  let tokenRange = Range(match.range, in: prompt),
                  let socketNumber = Int(prompt[numberRange]),
                  generator.imageGeneratorReferencePortIDs.indices.contains(socketNumber - 1) else {
                throw StudioError.validation("A reference mention in the prompt does not name a valid Reference socket.")
            }
            let portID = generator.imageGeneratorReferencePortIDs[socketNumber - 1]
            guard let runIndex = connectedPortIDs.firstIndex(of: portID) else {
                throw StudioError.validation("@reference \(socketNumber) is not connected to \(generator.label). Connect that Reference socket or remove the mention.")
            }
            resolved.replaceSubrange(tokenRange, with: "Reference image \(runIndex + 1)")
        }
        return resolved
    }
}
