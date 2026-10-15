import Foundation

/// A starting phrase for a Reference socket's role. These are noun phrases so the
/// composer can read them into "Reference image N is <phrase>."; the field stays
/// freely editable, and the inspector shows the composed result so unusual wording
/// is visible before it is sent.
struct ReferenceRolePreset: Identifiable, Hashable, Sendable {
    var id: String { title }
    let title: String
    let phrase: String

    /// Use this role when the first image supplies the subject's identity.
    static let all: [ReferenceRolePreset] = [
        .init(title: "Identity", phrase: "the authoritative identity and design source"),
        .init(title: "Style", phrase: "the visual style and colour reference"),
        .init(title: "Background", phrase: "the background and setting"),
        .init(title: "Product", phrase: "the product to place in the scene"),
        .init(title: "Pose", phrase: "the pose and composition guide")
    ]
}

/// A short, positional statement of what each connected reference image is for.
///
/// This is composed in app code and prepended *after* prompt compilation, so the
/// reference contract is never handed to the semantic expander. A small local
/// model paraphrasing "Reference
/// image 2 is the background" silently destroys the only signal that binds a role
/// to an image.
enum ReferenceRoleComposer {
    /// Long enough for a descriptive role, short enough that three of them cannot
    /// meaningfully erode the prompt's byte budget.
    static let maximumRoleLength = 200

    /// `connectedPortIDs` is the run order of the references actually supplied to
    /// the engine — not the socket layout of the node.
    ///
    /// This distinction is the whole point. Execution skips empty sockets, so
    /// leaving Reference 1 unconnected makes the canvas's "Reference 2" arrive as
    /// the engine's first `-r` image with RoPE index 1. Numbering from the
    /// connected list is what keeps the preamble true after any rewiring.
    static func preamble(connectedPortIDs: [String], roles: [String: String]) -> String {
        connectedPortIDs.enumerated().compactMap { index, portID in
            guard let role = normalized(roles[portID]) else { return nil }
            return "Reference image \(index + 1) is \(role)."
        }.joined(separator: "\n")
    }

    /// Roles are only meaningful to an adapter that indexes references
    /// positionally. `.startImageStrength` re-noises a single reference as a
    /// starting latent and `.maskedStartImage` uses an explicit mask; neither
    /// assigns a reference an index a prompt could name, so a preamble there is
    /// noise that competes with the creative prompt.
    static func preamble(roles: [String: String]?, connectedPortIDs: [String], conditioning: ImageConditioning) -> String {
        guard conditioning == .referenceImage, let roles else { return "" }
        return preamble(connectedPortIDs: connectedPortIDs, roles: roles)
    }

    /// The preamble establishes what the images *are* before the prompt says what
    /// to do with them. An absent preamble leaves the prompt byte-identical, so a
    /// workflow that sets no roles runs exactly as it did before this feature.
    static func apply(preamble: String, to prompt: String) -> String {
        preamble.isEmpty ? prompt : "\(preamble)\n\n\(prompt)"
    }

    /// Fails with a message naming the role text, rather than letting the engine
    /// report a bare "prompt up to 32 KB" once the preamble has already been
    /// folded in and the cause is no longer visible.
    static func compose(preamble: String, prompt: String, maximumBytes: Int) throws -> String {
        let composed = apply(preamble: preamble, to: prompt)
        guard composed.utf8.count <= maximumBytes else {
            throw StudioError.validation("The reference roles and prompt together exceed the \(maximumBytes)-byte limit for this recipe. Shorten the role descriptions or the prompt.")
        }
        return composed
    }

    /// The Reference sockets that actually have an image wired into them, in
    /// socket order. `imageGeneratorReferencePortIDs` is empty for every other node
    /// kind, so this reports nothing for them and never sees the text prompt port.
    static func connectedReferencePortIDs(node: StudioNode, edges: [StudioEdge]) -> [String] {
        let connected = Set(edges.filter { $0.targetID == node.id }.map(\.targetPortID))
        return node.imageGeneratorReferencePortIDs.filter { connected.contains($0) }
    }

    /// How a socket is announced in the editor. When an empty socket above it has
    /// shifted its position, the caption says so at the row itself — the preview
    /// alone shows the new number but not why it changed.
    static func socketCaption(label: String, socketIndex: Int, runPosition: Int) -> String {
        socketIndex == runPosition - 1 ? label : "\(label) → image \(runPosition)"
    }

    static func validate(roles: [String: String]) throws {
        for role in roles.values { try EnginePromptSyntax.validate(role) }
    }

    private static func normalized(_ role: String?) -> String? {
        guard let role else { return nil }
        var text = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumRoleLength { text = String(text.prefix(maximumRoleLength)) }
        // The composer supplies the sentence's period, so a role typed with one
        // does not end up with two.
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}
