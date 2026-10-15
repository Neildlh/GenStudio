import Foundation

/// Bridge for public MLX VLM model packages using GenStudio's app-owned,
/// version-pinned runtime. It never invokes a user-managed Python installation.
enum MLXVLMRuntime {
    static let engineID = "mlx-vlm"

    static func pythonExecutable() throws -> URL {
        try ManagedMLXRuntime.pythonExecutable(for: .vlm)
    }

    static func checkAvailability() async throws {
        try await ManagedMLXRuntime.checkEnvironment(family: .vlm)
    }

    static func generate(library: ModelLibrary, modelID: String, prompt: String, images: [URL], temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        try await checkAvailability()
        let installed = try await library.resolveInstalledModel(id: modelID)
        guard installed.engineID == engineID, installed.recipeSnapshot?.runtimeProfile == engineID,
              let capabilities = installed.recipeSnapshot?.workflowCapabilities,
              capabilities.contains(.textGeneration), !installed.components.isEmpty else {
            throw StudioError.validation("Choose a complete MLX VLM package from Models.")
        }
        let directory = installed.components[0].fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path),
              FileManager.default.fileExists(atPath: directory.appending(path: "tokenizer.json").path) else {
            throw StudioError.validation("This MLX package is incomplete. Reinstall it from the Model Library.")
        }
        let launcher = try ManagedMLXRuntime.launcher(named: "genstudio-mlx-vlm", family: .vlm)
        var arguments = ["--model", directory.path, "--prompt", prompt,
                         "--max-tokens", String(maxTokens), "--temperature", String(temperature)]
        if !images.isEmpty { arguments += ["--image"] + images.map(\.path) }
        GenerationProgressContext.report?(.init(stage: "Loading MLX model"))
        NativeRuntime.state("loading", model: modelID)
        defer { NativeRuntime.state("unloaded", model: modelID) }
        let result = try await NativeProcessRunner().run(executable: launcher, arguments: arguments, timeout: timeout, onOutput: { _ in
            NativeRuntime.state("running", model: modelID)
            GenerationProgressContext.report?(.init(stage: "Generating with MLX"))
        })
        guard result.status == 0 else {
            throw StudioError.validation("MLX VLM generation failed (\(result.status)): \(result.stderr.suffix(1800))")
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudioError.emptyResponse }
        try await library.markInferenceVerified(id: modelID)
        return text
    }
}
