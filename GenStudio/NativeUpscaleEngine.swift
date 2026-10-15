import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ImageUpscaleEngine: Sendable {
    func upscale(_ request: UpscaleRequest) async throws -> URL
}

/// Calls GenStudio's bundled `sd-cli` directly through `NativeProcessRunner` — no server, no external
/// application. Every invocation owns its process and releases model/GPU resources on exit, exactly like
/// NativeImageEngine/NativeWanVideoEngine.
actor NativeUpscaleEngine: ImageUpscaleEngine {
    private let library: ModelLibrary
    private let outputRoot: URL
    private let resourceRoot: URL?
    private let executableOverride: URL?
    private let capabilities: [UpscaleCapability]
    /// `executableOverride` mirrors NativeWanVideoEngine's seam: unit tests substitute a fixture
    /// script for sd-cli to exercise exit-code/error-marker/dimension validation without real weights.
    init(library: ModelLibrary, outputRoot: URL, resourceRoot: URL? = Bundle.main.resourceURL, executableOverride: URL? = nil, capabilities: [UpscaleCapability] = UpscaleCapabilityRegistry.shipped) {
        self.library = library; self.outputRoot = outputRoot; self.resourceRoot = resourceRoot; self.executableOverride = executableOverride; self.capabilities = capabilities
    }

    /// Runtime error markers observed for a zero-exit failure. The rejected official x2 checkpoint returns
    /// status 0, prints one of these, and copies the input unchanged — see the brief's "Rejected x2
    /// checkpoint" section. Exit status alone is never treated as success.
    static let errorMarkers = ["[error", "upscale failed", "new_upscaler_ctx failed"]

    func upscale(_ request: UpscaleRequest) async throws -> URL {
        guard let capability = UpscaleCapabilityRegistry.capability(recipeID: request.recipeID, in: capabilities), capability.engineBuild == request.engineBuild else {
            throw StudioError.validation("Recipe \(request.recipeID) has no upscale adapter in GenStudio.")
        }
        // Proof is a label, not a permission; see NativeGenerationEngine. Only a withdrawn
        // route is blocked, and the decoded result records this recipe's first proof.
        if case .unavailable(let reason) = capability.readiness {
            throw StudioError.validation(reason)
        }
        guard try MediaIdentity.of(request.sourceImage) == request.sourceIdentity else {
            throw StudioError.validation("The source image changed on disk after it was prepared. Run the workflow again.")
        }
        guard let sourceImageSource = CGImageSourceCreateWithURL(request.sourceImage as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(sourceImageSource, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int, let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw StudioError.validation("The source image cannot be decoded.")
        }
        // Bounds only; readiness/proof was already gated explicitly above with a clearer message.
        try UpscaleRequestPlanner.validate(recipeID: request.recipeID, scale: request.scale, tileSize: request.tileSize, sourceWidth: sourceWidth, sourceHeight: sourceHeight, registry: capabilities)
        let x4Width = sourceWidth * 4, x4Height = sourceHeight * 4
        let finalWidth = request.scale == 4 ? x4Width : sourceWidth * 2
        let finalHeight = request.scale == 4 ? x4Height : sourceHeight * 2

        GenerationProgressContext.report?(.init(stage: "Validating model files"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        guard installed.kind == .upscaler, installed.engineID == "stable-diffusion.cpp", let checkpoint = installed.componentURL(role: "checkpoint") else {
            throw StudioError.validation("The installed \(installed.name) recipe is incomplete. Reinstall or re-import all of its components.")
        }

        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        guard let requiredBytes = UpscaleDiskPreflight.requiredBytes(x4Width: x4Width, x4Height: x4Height, finalWidth: finalWidth, finalHeight: finalHeight) else {
            throw StudioError.validation("Could not establish the disk space required for this upscale.")
        }
        guard UpscaleDiskPreflight.freeBytes(at: outputRoot) >= requiredBytes else {
            throw StudioError.validation("Not enough free disk space for the temporary 4× render and final image. Free at least \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)) and try again.")
        }

        let executable: URL
        if let executableOverride { executable = executableOverride } else { executable = try NativeRuntime.executable("sd", resourceRoot: resourceRoot) }
        // Named as a bare UUID.png (not "...-x4.png") because when scale == 4 this file IS the final,
        // retained artifact: ExecutionQueue's scratch-cleanup guard only recognizes that exact filename
        // shape. It is deleted here instead whenever scale == 2 produces a separate downsampled file.
        let x4Output = outputRoot.appending(path: "\(UUID().uuidString).png")
        var outputsToRemoveOnFailure = [x4Output]
        var success = false
        defer {
            if !success {
                for output in outputsToRemoveOnFailure { try? FileManager.default.removeItem(at: output) }
            }
        }
        let arguments = try UpscaleAdapterCommand.arguments(request, capability: capability, checkpoint: checkpoint, output: x4Output)

        GenerationProgressContext.report?(.init(stage: "Loading model"))
        NativeRuntime.state("loading", model: request.recipeID); defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        GenerationProgressContext.report?(.init(stage: "Upscaling"))
        let result = try await NativeProcessRunner().run(executable: executable, arguments: arguments, timeout: .seconds(3600))
        guard result.status == 0 else {
            throw StudioError.validation("Local upscaling failed (\(result.status)): \(result.stderr.suffix(1800)) \(result.stdout.suffix(800))")
        }
        let combined = result.stdout + "\n" + result.stderr
        let normalizedOutput = combined.lowercased()
        guard !Self.errorMarkers.contains(where: { normalizedOutput.contains($0) }) else {
            throw StudioError.validation("Local upscaling reported a runtime error even though the process exited successfully: \(combined.suffix(1800))")
        }
        guard let x4Source = CGImageSourceCreateWithURL(x4Output as CFURL, nil), CGImageSourceGetType(x4Source) as String? == "public.png",
              let x4Image = CGImageSourceCreateImageAtIndex(x4Source, 0, nil), x4Image.width == x4Width, x4Image.height == x4Height else {
            throw StudioError.validation("The upscale engine did not return a valid \(x4Width)×\(x4Height) PNG. An unchanged or wrong-size result (as the rejected x2 checkpoint produces) is never accepted.")
        }
        try Task.checkCancellation()

        let finalOutput: URL
        if request.scale == 4 {
            finalOutput = x4Output
        } else {
            let downsampled = outputRoot.appending(path: "\(UUID().uuidString).png")
            outputsToRemoveOnFailure.append(downsampled)
            do { try Self.downsample(x4Output, width: finalWidth, height: finalHeight, to: downsampled) }
            catch { throw StudioError.validation("Downsampling the validated 4× render to 2× failed: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: x4Output)
            guard let finalSource = CGImageSourceCreateWithURL(downsampled as CFURL, nil), CGImageSourceGetType(finalSource) as String? == "public.png",
                  let finalImage = CGImageSourceCreateImageAtIndex(finalSource, 0, nil), finalImage.width == finalWidth, finalImage.height == finalHeight else {
                try? FileManager.default.removeItem(at: downsampled)
                throw StudioError.validation("The 2× downsample did not produce a valid \(finalWidth)×\(finalHeight) PNG.")
            }
            finalOutput = downsampled
        }
        try Task.checkCancellation()
        // A decoded, dimension-verified render is the proof for this exact recipe. Do not turn a
        // successful upscale into a failed run merely because registry bookkeeping could not be written.
        try? await library.markUpscaleInferenceVerified(id: request.recipeID)
        success = true
        return finalOutput
    }

    /// High-quality bounded downsample of the validated x4 PNG to the requested 2× size. Mirrors
    /// MediaProcessor.resize's canvas settings; kept local because this is the only caller and the
    /// intermediate lives in scratch space, not MediaProcessor's retained Artifacts directory.
    private static func downsample(_ input: URL, width: Int, height: Int, to output: URL) throws {
        guard width > 0, height > 0, width <= UpscaleRequestPlanner.maximumSide, height <= UpscaleRequestPlanner.maximumSide, width * height <= UpscaleRequestPlanner.maximumPixels else {
            throw StudioError.validation("Downsample dimensions must be positive and within GenStudio's image bounds.")
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StudioError.validation("The 4× render could not be decoded for downsampling.")
        }
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudioError.validation("Could not create the downsample canvas.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw StudioError.validation("Downsample produced no pixels.") }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError.persistence("Could not create the downsampled image artifact.")
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination), FileManager.default.isReadableFile(atPath: output.path) else {
            throw StudioError.persistence("The downsampled image artifact could not be validated.")
        }
    }
}
