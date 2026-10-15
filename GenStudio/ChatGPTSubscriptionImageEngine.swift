import Foundation
import ImageIO

/// Experimental, unofficial: adapts ChatGPTSubscriptionImageClient into GenStudio's
/// ImageGenerationEngine protocol so a signed-in ChatGPT subscription can sit alongside
/// the bundled local recipes. See ChatGPTSubscriptionAuth.swift for why this is
/// unsupported by OpenAI and what it risks.
actor ChatGPTSubscriptionImageEngine: ImageGenerationEngine {
    static let recipeID = "chatgpt-images-subscription"
    static let engineID = "chatgpt-images-subscription"

    private let authenticator: ChatGPTSubscriptionAuthenticator
    private let client: ChatGPTSubscriptionImageClient
    private let outputRoot: URL

    init(authenticator: ChatGPTSubscriptionAuthenticator, client: ChatGPTSubscriptionImageClient = ChatGPTSubscriptionImageClient(), outputRoot: URL) {
        self.authenticator = authenticator
        self.client = client
        self.outputRoot = outputRoot
    }

    func generate(_ request: ImageGenerationRequest) async throws -> URL {
        guard request.recipeID == Self.recipeID else {
            throw StudioError.validation("This request is not addressed to the ChatGPT subscription engine.")
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.validation("Use a nonempty prompt.")
        }
        let session: (accessToken: String, accountID: String?)
        do {
            session = try await authenticator.validSession()
        } catch ChatGPTSubscriptionAuthError.notSignedIn {
            throw StudioError.validation("Not signed in to your ChatGPT subscription. Open GenStudio → Settings to connect it.")
        } catch {
            throw StudioError.validation("ChatGPT sign-in could not be refreshed: \(String(describing: error))")
        }

        let references = try request.referenceImages.map { url -> ChatGPTImageReference in
            let data = try Data(contentsOf: url)
            let mimeType = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? "image/jpeg" : "image/png"
            return ChatGPTImageReference(data: data, mimeType: mimeType)
        }
        let size = ChatGPTSubscriptionImageConfig.nearestSupportedSize(width: request.width, height: request.height)
        let clientRequest = ChatGPTImageGenerationRequest(prompt: request.prompt, references: references, size: size.api, outputFormat: "png")

        let imageData: Data
        do {
            imageData = try await client.generateImage(clientRequest, accessToken: session.accessToken, accountID: session.accountID)
        } catch let error as ChatGPTSubscriptionImageError {
            throw StudioError.validation(error.description)
        }

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw StudioError.validation("ChatGPT returned data that could not be decoded as an image.")
        }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let output = outputRoot.appending(path: "\(UUID().uuidString).png")
        try imageData.write(to: output, options: .atomic)
        try Task.checkCancellation()
        return output
    }
}

/// Dispatches an image request to the local on-device engine or the ChatGPT subscription
/// engine, keyed by the matched capability's engineID — the same pattern
/// LocalVideoEngineRouter already uses to pick between local video backends.
struct ImageEngineRouter: ImageGenerationEngine {
    let local: any ImageGenerationEngine
    let chatGPTSubscription: any ImageGenerationEngine
    let registry: [ImageCapability]

    init(local: any ImageGenerationEngine, chatGPTSubscription: any ImageGenerationEngine, registry: [ImageCapability] = ImageCapabilityRegistry.shipped) {
        self.local = local
        self.chatGPTSubscription = chatGPTSubscription
        self.registry = registry
    }

    func generate(_ request: ImageGenerationRequest) async throws -> URL {
        guard let capability = ImageCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task, in: registry) else {
            return try await local.generate(request)
        }
        switch capability.engineID {
        case ChatGPTSubscriptionImageEngine.engineID: return try await chatGPTSubscription.generate(request)
        default: return try await local.generate(request)
        }
    }
}
