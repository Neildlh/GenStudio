import Foundation

/// Distinct upscale contract. Unlike Image/Video generation there is exactly one task (enlarge an existing
/// image), so there is no per-task enum: the requested scale (2× or 4×) is a request parameter, not a
/// separate capability descriptor. Keyed to the exact recipe and engine build, like ImageCapability/VideoCapability.
struct UpscaleCapability: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(recipeID)@\(engineBuild)" }
    let recipeID: String
    let engineID: String
    let engineBuild: String
    /// Tile size passed to sd-cli when the node's own tile setting is Auto (0).
    let defaultTileSize: Int
    let readiness: CapabilityReadiness
    let qualityNote: String
    let measuredBaseline: String?

    func with(readiness: CapabilityReadiness) -> UpscaleCapability {
        .init(recipeID: recipeID, engineID: engineID, engineBuild: engineBuild, defaultTileSize: defaultTileSize, readiness: readiness, qualityNote: qualityNote, measuredBaseline: measuredBaseline)
    }
}

enum UpscaleCapabilityRegistry {
    static let realesrganX4PlusRecipeID = "realesrgan-x4plus"
    static let realesrganX4PlusAnimeRecipeID = "realesrgan-x4plus-anime-6b"

    /// Both recipes were decoded at 2× and 4× through NativeUpscaleEngine on the target M1 Max.
    /// The evidence records the exact checkpoint digest, engine build, output identities and timings.
    static let x4Plus = UpscaleCapability(
        recipeID: realesrganX4PlusRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, defaultTileSize: 128,
        readiness: .verified(evidence: "docs/evidence/upscaling/realesrgan-x4plus.json"),
        qualityNote: "General model for photography and mixed artwork. Learned detail may modify faces, text, logos and fine patterns; compare with the source at 100% and use Image Resize instead where exact pixels matter.",
        measuredBaseline: "Verified through GenStudio on Apple M1 Max / 64 GB (15 Sep 2026): a 64×64 input produced validated 256×256 and 128×128 outputs in about 1.66 and 1.61 seconds. A separate 256×256 tiled proof produced 1024×1024 in about 20.56 seconds; larger sources take longer. Video-frame rate measured 18 Sep 2026: 320×192 → 1280×768 costs about 11.15 s per frame (10.83–11.63 s over nine frames), of which 10.15 s is upscale compute and only 0.20 s is model loading. Tile size 128 is optimal — 64 measured 12.54 s and 256 measured 10.93 s.")

    static let x4PlusAnime = UpscaleCapability(
        recipeID: realesrganX4PlusAnimeRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, defaultTileSize: 128,
        readiness: .verified(evidence: "docs/evidence/upscaling/realesrgan-x4plus-anime-6b.json"),
        qualityNote: "Illustration and animation model for flat art, animation and line work. Learned detail may modify faces, text, logos and fine patterns; compare with the source at 100% and use Image Resize instead where exact pixels matter.",
        measuredBaseline: "Verified through GenStudio on Apple M1 Max / 64 GB (15 Sep 2026): a 64×64 input produced validated 256×256 and 128×128 outputs in about 12.35 and 0.58 seconds. The first run included Metal/model initialization; full-size timing remains unmeasured.")

    static let shipped: [UpscaleCapability] = [x4Plus, x4PlusAnime]

    static func capability(recipeID: String, in registry: [UpscaleCapability] = shipped) -> UpscaleCapability? { registry.first { $0.recipeID == recipeID } }
    static func supportsRecipe(_ recipeID: String, in registry: [UpscaleCapability] = shipped) -> Bool { registry.contains { $0.recipeID == recipeID && $0.readiness.proven } }
    static func hasAdapter(_ recipeID: String, in registry: [UpscaleCapability] = shipped) -> Bool { registry.contains { $0.recipeID == recipeID } }
    static func hasUsableAdapter(_ recipeID: String, in registry: [UpscaleCapability] = shipped) -> Bool {
        registry.contains { $0.recipeID == recipeID && $0.readiness.adapterAvailable }
    }
}

/// Curated upscaler recipes for the bundled stable-diffusion.cpp build. Both are byte-for-byte AMD mirrors of
/// the official xinntao/Real-ESRGAN release assets (see the brief). Independently re-verified against
/// Hugging Face's `x-linked-size`/`x-linked-etag` response headers for both pinned revisions on 15 Sep 2026;
/// both files begin with the ZIP local-file signature `50 4B 03 04` (the modern `torch.save` container), not
/// GGUF or safetensors — see ModelLibraryCore's `.pth` handling. Released entries are immutable; a changed
/// file must become a new recipe id.
enum UpscalerModelCatalog {
    static let recipes: [ModelRecipe] = [
        .init(id: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, name: "Real-ESRGAN x4plus · General", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [
            .init(id: "checkpoint", role: "checkpoint", repository: "amd/realesrgan-x4plus", revision: "bda69abcaf525425b371622349e975245ae090c2", filename: "RealESRGAN_x4plus.pth", byteSize: 67_040_989, sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1", license: "BSD-3-Clause; unchanged mirror of the official xinntao/Real-ESRGAN release asset")
        ], runtimeReady: false, minimumMemoryBytes: 4 * 1024 * 1024 * 1024),
        .init(id: UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID, name: "Real-ESRGAN x4plus anime 6B · Illustration", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [
            .init(id: "checkpoint", role: "checkpoint", repository: "amd/realesrgan-x4plus-anime-6b", revision: "b14ff5f8ecb5a4b56ce4049a58d0bca1f8814690", filename: "RealESRGAN_x4plus_anime_6B.pth", byteSize: 17_938_799, sha256: "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da", license: "BSD-3-Clause; unchanged mirror of the official xinntao/Real-ESRGAN release asset")
        ], runtimeReady: false, minimumMemoryBytes: 2 * 1024 * 1024 * 1024)
    ]
}

/// A fully resolved upscale job: every value the adapter uses and provenance records.
struct UpscaleRequest: Codable, Hashable, Sendable {
    let recipeID: String
    let engineBuild: String
    /// 2 or 4. A 2× request still renders the full proven 4× model, then downsamples (see NativeUpscaleEngine).
    let scale: Int
    /// Resolved concrete tile size actually passed to sd-cli (Auto is resolved before the request is made).
    let tileSize: Int
    /// Prepared/validated input file actually passed to the engine, with its content identity.
    var sourceImage: URL
    var sourceIdentity: MediaIdentity
    /// True only when the workflow explicitly authorized a first run of this exact recipe before local
    /// decoded-output proof existed.
    var allowsUnverifiedLocalRun: Bool? = nil
}

enum UpscaleRequestPlanner {
    static let maximumSide = 16_384
    static let maximumPixels = 67_108_864
    /// 0 means Auto (resolved to the capability's default tile size before launch).
    static let tileChoices: Set<Int> = [0, 64, 128, 256]

    static func resolvedTileSize(_ requested: Int, defaultTileSize: Int) -> Int { requested == 0 ? defaultTileSize : requested }

    /// Recipe/scale/tile validation only — no connected image is required. Used by GraphValidator before a
    /// workflow runs, since the source image's actual pixel dimensions are not known until it is decoded at
    /// execution time (the node stores no width/height of its own, unlike Image Generator).
    @discardableResult
    static func validateSettings(recipeID: String, scale: Int, tileSize: Int, registry: [UpscaleCapability]) throws -> UpscaleCapability {
        guard let capability = UpscaleCapabilityRegistry.capability(recipeID: recipeID, in: registry) else {
            throw StudioError.validation("Recipe \(recipeID) has no upscale adapter in GenStudio.")
        }
        // Proof is a label, not a permission; see ImageRequestPlanner.validate.
        if case .unavailable(let reason) = capability.readiness { throw StudioError.validation(reason) }
        guard scale == 2 || scale == 4 else { throw StudioError.validation("Upscale factor must be 2 or 4.") }
        guard tileChoices.contains(tileSize) else { throw StudioError.validation("Tile size must be Auto, 64, 128 or 256.") }
        return capability
    }

    /// Full validation shared by preflight and execution, once the connected image's exact pixel dimensions
    /// are known. Throws before any model loads. Bounds are checked against the eventual 4× result (the
    /// model always renders at 4×; 2× is a downsample of that), never against the raw source alone, so a
    /// request that would only overflow after upscaling is still rejected up front.
    @discardableResult
    static func validate(recipeID: String, scale: Int, tileSize: Int, sourceWidth: Int, sourceHeight: Int, registry: [UpscaleCapability]) throws -> UpscaleCapability {
        let capability = try validateSettings(recipeID: recipeID, scale: scale, tileSize: tileSize, registry: registry)
        guard sourceWidth > 0, sourceHeight > 0 else { throw StudioError.validation("The connected image has invalid dimensions.") }
        guard sourceWidth <= maximumSide, sourceHeight <= maximumSide else {
            throw StudioError.validation("Image Upscale accepts inputs up to \(maximumSide) pixels per side.")
        }
        let (x4Width, widthOverflow) = sourceWidth.multipliedReportingOverflow(by: 4)
        let (x4Height, heightOverflow) = sourceHeight.multipliedReportingOverflow(by: 4)
        guard !widthOverflow, !heightOverflow, x4Width <= maximumSide, x4Height <= maximumSide else {
            throw StudioError.validation("The required 4× render would exceed \(maximumSide) pixels per side. Use a smaller source image.")
        }
        let (x4Pixels, pixelsOverflow) = x4Width.multipliedReportingOverflow(by: x4Height)
        guard !pixelsOverflow, x4Pixels <= maximumPixels else {
            throw StudioError.validation("The required 4× render would exceed \(maximumPixels) pixels. Use a smaller source image.")
        }
        return capability
    }

    static func makeRequest(recipeID: String, scale: Int, tileSize: Int, sourceWidth: Int, sourceHeight: Int, registry: [UpscaleCapability], allowsUnverifiedLocalRun: Bool = false, sourceImage: URL, sourceIdentity: MediaIdentity) throws -> (UpscaleRequest, UpscaleCapability) {
        let capability = try validate(recipeID: recipeID, scale: scale, tileSize: tileSize, sourceWidth: sourceWidth, sourceHeight: sourceHeight, registry: registry)
        let resolvedTile = resolvedTileSize(tileSize, defaultTileSize: capability.defaultTileSize)
        return (.init(recipeID: recipeID, engineBuild: capability.engineBuild, scale: scale, tileSize: resolvedTile, sourceImage: sourceImage, sourceIdentity: sourceIdentity, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun ? true : nil), capability)
    }
}

/// Exact sd-cli argument mapping for the proven upscale command profile. Pure, so it is tested without weights.
enum UpscaleAdapterCommand {
    static func arguments(_ request: UpscaleRequest, capability: UpscaleCapability, checkpoint: URL, output: URL) throws -> [String] {
        guard request.recipeID == capability.recipeID, request.engineBuild == capability.engineBuild else {
            throw StudioError.validation("This upscale request does not match its recipe adapter.")
        }
        guard [64, 128, 256].contains(request.tileSize) else { throw StudioError.validation("Resolved tile size must be 64, 128 or 256.") }
        return ["-M", "upscale", "--upscale-model", checkpoint.path, "--upscale-tile-size", String(request.tileSize), "-i", request.sourceImage.path, "-o", output.path]
    }
}

/// Checked, overflow-safe disk-space accounting for the temporary x4 intermediate plus the final PNG. The
/// brief requires a preflight check because a 2× request still needs a full x4 render on disk before the
/// bounded downsample runs.
enum UpscaleDiskPreflight {
    /// Worst-case uncompressed RGBA8 bytes for both the x4 intermediate and the final output resident on
    /// disk at once, plus a fixed reserve. Nil means the estimate could not be established safely (overflow
    /// or invalid dimensions); callers must treat nil as blocking, never as zero.
    static func requiredBytes(x4Width: Int, x4Height: Int, finalWidth: Int, finalHeight: Int) -> Int64? {
        func area(_ width: Int, _ height: Int) -> Int64? {
            guard width > 0, height > 0 else { return nil }
            let product = Int64(width).multipliedReportingOverflow(by: Int64(height))
            return product.overflow ? nil : product.partialValue
        }
        guard let x4Area = area(x4Width, x4Height), let finalArea = area(finalWidth, finalHeight) else { return nil }
        let bytesPerPixel: Int64 = 4
        let reserve: Int64 = 64 * 1024 * 1024
        let x4Bytes = x4Area.multipliedReportingOverflow(by: bytesPerPixel)
        let finalBytes = finalArea.multipliedReportingOverflow(by: bytesPerPixel)
        guard !x4Bytes.overflow, !finalBytes.overflow else { return nil }
        let sum = x4Bytes.partialValue.addingReportingOverflow(finalBytes.partialValue)
        guard !sum.overflow else { return nil }
        let withReserve = sum.partialValue.addingReportingOverflow(reserve)
        return withReserve.overflow ? nil : withReserve.partialValue
    }

    /// Free bytes on the volume containing `url`, walking up to an existing ancestor directory like
    /// HardwareProfile.current does, so a not-yet-created scratch directory can still be checked.
    static func freeBytes(at url: URL) -> Int64 {
        var directory = url
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
