import Foundation

/// Curated image/video recipes for the bundled stable-diffusion.cpp build.
/// Every component's revision, byte size, SHA-256 and declared license was read from the Hugging Face API on
/// 2026-09-15 and is retained in docs/research/model-expansion/evidence/hub. Released entries are immutable;
/// a changed file must become a new recipe id. Adapter presence and local proof live in the capability registries.
enum MediaModelCatalog {
    static let animateDiffRecipeID = "animatediff-v3-sd15-q4"
    static let lingBotRecipeID = "lingbot-video-dense-13b"
    static let wan22TI2VRecipeID = "wan22-ti2v-5b-q4km"
    static let kleinRecipeID = "flux2-klein-4b-q4"
    static let klein9BRecipeID = "flux2-klein-9b-q4"
    /// Tongyi-MAI's 6B few-step image model. Apache-2.0, so it is the commercial-use image option.
    static let zImageTurboRecipeID = "z-image-turbo-q8"
    /// A deliberately different image family from the FLUX.2 core: a single-file
    /// SDXL photorealism checkpoint published by RunDiffusion.
    static let juggernautXLRecipeID = "juggernaut-xl-v9"
    static let ltx23RecipeID = "ltx23-dev-22b-q4km"
    static let ltx25RecipeID = "ltx25-dev-22b-q4km"
    static let wan21FLFRecipeID = "wan21-flf2v-14b-720p-q4km"
    static let minimaxH3RecipeID = "minimax-h3-fl2va-q4km"
    /// MiniMax-H3's reference-video route is a distinct checkpoint from FL2VA.
    /// Keeping it as its own recipe prevents the installer from silently pairing a
    /// FL2VA transformer with Ref2VA arguments (which produces an invalid job).
    static let minimaxH3Ref2VARecipeID = "minimax-h3-ref2va-q4km"

    private static func legacy(_ recipeID: String, _ componentID: String) -> ModelComponent {
        ModelCatalog.legacyRecipes.first { $0.id == recipeID }!.components.first { $0.id == componentID }!
    }
    /// All weights resident plus 2 GiB of runtime overhead, rounded up to whole GiB. A floor, not a measurement:
    /// activations, VAE decode buffers and other applications are extra.
    static func weightFloorBytes(_ components: [ModelComponent]) -> UInt64 {
        let gib: UInt64 = 1024 * 1024 * 1024
        let total = components.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.byteSize)) } + 2 * gib
        return (total + gib - 1) / gib * gib
    }
    private static func recipe(_ id: String, _ name: String, _ kind: GenerationModelKind, _ components: [ModelComponent]) -> ModelRecipe {
        .init(id: id, name: name, kind: kind, engineID: "stable-diffusion.cpp", components: components, runtimeReady: false, minimumMemoryBytes: weightFloorBytes(components))
    }

    /// Qwen3-4B text encoder shared by Klein 4B and Z-Image Turbo: identical bytes, so a second install reuses it.
    private static let qwen3_4BTextEncoder = ModelComponent(id: "textEncoder", role: "textEncoder", repository: "unsloth/Qwen3-4B-GGUF", revision: "22c9fc8a8c7700b76a1789366280a6a5a1ad1120", filename: "Qwen3-4B-Q4_K_M.gguf", byteSize: 2497281312, sha256: "f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a", license: "Apache-2.0")

    static let recipes: [ModelRecipe] = [
        recipe(animateDiffRecipeID, "AnimateDiff v3 · SD 1.5 Q4_0", .video, [
            legacy("sd15-q4", "checkpoint"),
            .init(id: "motionModule", role: "motionModule", repository: "conrevo/AnimateDiff-A1111", revision: "aa4a0ef5bd366a0ec898e7a64b6fc0f612e37444", filename: "motion_module/mm_sd15_v3.safetensors", byteSize: 836618008, sha256: "a8ca0eadb18c6ad6652bca344a458f31780901a87f765bf95a81ef9c5be55f29", license: "Not declared by conrevo/AnimateDiff-A1111; its README describes fp16 safetensors conversions of guoyww/animatediff (Apache-2.0)")
        ]),
        recipe(lingBotRecipeID, "LingBot-Video Dense 1.3B", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "robbyant/lingbot-video-dense-1.3b", revision: "f9789a7d9b4772a47aba62d4eb5282ddefd1da21", filename: "transformer/diffusion_pytorch_model.safetensors", byteSize: 2791967328, sha256: "948b15845c0fe24fdfa598204ffc2d80b96a4ad2ab5b03d303f0b6d8b0e9b494", license: "Apache-2.0"),
            .init(id: "textEncoder", role: "textEncoder", repository: "Qwen/Qwen3-VL-4B-Instruct-GGUF", revision: "1cd86afb9a95c410a6038ab3b40d8b578c892266", filename: "Qwen3VL-4B-Instruct-Q4_K_M.gguf", byteSize: 2497281664, sha256: "66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a", license: "Apache-2.0"),
            legacy(VideoCapabilityRegistry.wanT2VRecipeID, "vae")
        ]),
        recipe(wan22TI2VRecipeID, "Wan 2.2 TI2V 5B · Q4_K_M", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "QuantStack/Wan2.2-TI2V-5B-GGUF", revision: "57437632ddd08bdcbd1508c866aa22e126ed51d2", filename: "Wan2.2-TI2V-5B-Q4_K_M.gguf", byteSize: 3433116000, sha256: "95b19697b7f98e65b0a543640e9ca7b4dfec32e2a6e3731e8e10708be52655e2", license: "Apache-2.0"),
            legacy(VideoCapabilityRegistry.wanT2VRecipeID, "textEncoder"),
            .init(id: "vae", role: "vae", repository: "Comfy-Org/Wan_2.2_ComfyUI_Repackaged", revision: "c4f60d30c55a624e35427060fdd217579a6c1d77", filename: "split_files/vae/wan2.2_vae.safetensors", byteSize: 1409400960, sha256: "e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156", license: "Apache-2.0")
        ]),
        recipe(wan21FLFRecipeID, "Wan 2.1 FLF2V 14B 720P · Q4_K_M", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "city96/Wan2.1-FLF2V-14B-720P-gguf", revision: "0fef557a0a13cbe66000526d2161436e693de93a", filename: "wan2.1-flf2v-14b-720p-Q4_K_M.gguf", byteSize: 11343816128, sha256: "7652d7d8b0795009ff21ed83d806af762aae8a8faa8640dd07b3a67e4dfab445", license: "Apache-2.0"),
            legacy(VideoCapabilityRegistry.wanT2VRecipeID, "textEncoder"),
            legacy(VideoCapabilityRegistry.wanT2VRecipeID, "vae"),
            .init(id: "clipVision", role: "clipVision", repository: "Comfy-Org/Wan_2.1_ComfyUI_repackaged", revision: "617a7633e636506f850e043bc4605f290a466a8e", filename: "split_files/clip_vision/clip_vision_h.safetensors", byteSize: 1264219396, sha256: "64a7ef761bfccbadbaa3da77366aac4185a6c58fa5de5f589b42a65bcc21f161", license: "Apache-2.0")
        ]),
        recipe(minimaxH3RecipeID, "MiniMax-H3 FL2VA · Q4_K_M (video only)", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "leejet/MiniMax-H3-GGUF", revision: "d9c4c6312b4728a68a15a35626d84775a6523783", filename: "minimax_h3_fl2va_pruned-Q4_K_M.gguf", byteSize: 11420663904, sha256: "dd948e08ad0ba3c71bd42f368e283dd82e790f5122a63b276e22a3e0283d0c10", license: "See MiniMax-H3 model card and repository terms"),
            .init(id: "textEncoder", role: "textEncoder", repository: "leejet/MiniMax-H3-GGUF", revision: "d9c4c6312b4728a68a15a35626d84775a6523783", filename: "qwen3vl_32b_minimax_h3-Q4_K_M.gguf", byteSize: 18218065024, sha256: "11e6efe70a57ce7f4838c47bdbd1a1c4b8ce10e2b7747f1b065990b70f4b05fc", license: "See MiniMax-H3 model card and repository terms"),
            .init(id: "vae", role: "vae", repository: "Comfy-Org/MiniMax-H3", revision: "a98869194787969724c7425d95d0ed73ce9202af", filename: "vae/minimax_h3_video_vae_fp16.safetensors", byteSize: 5207808496, sha256: "7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522", license: "See MiniMax-H3 model card and repository terms")
        ]),
        recipe(minimaxH3Ref2VARecipeID, "MiniMax-H3 Ref2VA · Q4_K_M (video only)", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "leejet/MiniMax-H3-GGUF", revision: "d9c4c6312b4728a68a15a35626d84775a6523783", filename: "minimax_h3_ref2va_pruned-Q4_K_M.gguf", byteSize: 11420663904, sha256: "9ca1aef9f4609a56c2c751484013e1b20fe352f892122e5ab0a428fb95a7956e", license: "See MiniMax-H3 model card and repository terms"),
            .init(id: "textEncoder", role: "textEncoder", repository: "leejet/MiniMax-H3-GGUF", revision: "d9c4c6312b4728a68a15a35626d84775a6523783", filename: "qwen3vl_32b_minimax_h3-Q4_K_M.gguf", byteSize: 18218065024, sha256: "11e6efe70a57ce7f4838c47bdbd1a1c4b8ce10e2b7747f1b065990b70f4b05fc", license: "See MiniMax-H3 model card and repository terms"),
            .init(id: "vae", role: "vae", repository: "Comfy-Org/MiniMax-H3", revision: "a98869194787969724c7425d95d0ed73ce9202af", filename: "vae/minimax_h3_video_vae_fp16.safetensors", byteSize: 5207808496, sha256: "7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522", license: "See MiniMax-H3 model card and repository terms")
        ]),
        recipe(kleinRecipeID, "FLUX.2 Klein 4B · Q4_0", .image, [
            .init(id: "diffusion", role: "diffusion", repository: "leejet/FLUX.2-klein-4B-GGUF", revision: "3b1f5a9dc3abb32238b053aeb3d823c30afdacbd", filename: "flux-2-klein-4b-Q4_0.gguf", byteSize: 2460378560, sha256: "d1023499ef3f2f82ff7c50e6778495195c1b6cc34835741778868428111f9ff4", license: "Apache-2.0"),
            qwen3_4BTextEncoder,
            .init(id: "vae", role: "vae", repository: "Comfy-Org/flux2-klein-4B", revision: "5f526678002e43af5551dadb73ce2e8c91b43afe", filename: "split_files/vae/flux2-vae.safetensors", byteSize: 336211292, sha256: "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3", license: "Apache-2.0 as declared by Comfy-Org/flux2-klein-4B (identical bytes are also published in the gated black-forest-labs/FLUX.2-dev repository under its own terms)")
        ]),
        recipe(juggernautXLRecipeID, "Juggernaut XL v9 · SDXL photorealism", .image, [
            .init(id: "checkpoint", role: "checkpoint", repository: "RunDiffusion/Juggernaut-XL-v9", revision: "cf419233522daa0b9ea36c3aff98fa2cab1fb0fb", filename: "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors", byteSize: 7105348188, sha256: "c9e3e68f89b8e38689e1097d4be4573cf308de4e3fd044c64ca697bdb4aa8bca", license: "CreativeML Open RAIL-M")
        ]),
        recipe(klein9BRecipeID, "FLUX.2 Klein 9B · Q4_0", .image, [
            .init(id: "diffusion", role: "diffusion", repository: "leejet/FLUX.2-klein-9B-GGUF", revision: "cc588497a95ffc2937ebbd6b9b3916a11ada6e5b", filename: "flux-2-klein-9b-Q4_0.gguf", byteSize: 5616208032, sha256: "a7e77afa96871d16679ff7b949bd25f20c8179f219c4b662cac91e81ed99b944", license: "FLUX Non-Commercial License (review upstream terms)"),
            .init(id: "textEncoder", role: "textEncoder", repository: "unsloth/Qwen3-8B-GGUF", revision: "a6adef130ffb23ddaf1a62fec9dced968c9bc482", filename: "Qwen3-8B-Q4_K_M.gguf", byteSize: 5027784512, sha256: "120307ba529eb2439d6c430d94104dabd578497bc7bfe7e322b5d9933b449bd4", license: "Apache-2.0"),
            .init(id: "vae", role: "vae", repository: "Comfy-Org/flux2-klein-4B", revision: "5f526678002e43af5551dadb73ce2e8c91b43afe", filename: "split_files/vae/flux2-vae.safetensors", byteSize: 336211292, sha256: "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3", license: "Apache-2.0 as declared by Comfy-Org/flux2-klein-4B")
        ]),
        // Pinned 2026-10-14 (docs/research/model-expansion/evidence/hub/leejet__Z-Image-Turbo-GGUF.json and
        // Comfy-Org__z_image_turbo.json). The VAE is the FLUX.1 autoencoder the engine's z_image.md documents; the
        // Comfy-Org copy is public and has the same SHA-256 as the gated black-forest-labs one.
        recipe(zImageTurboRecipeID, "Z-Image Turbo · Q8_0", .image, [
            .init(id: "diffusion", role: "diffusion", repository: "leejet/Z-Image-Turbo-GGUF", revision: "c61c0e422dc8b541b7548cf33a4ef8302b0f8085", filename: "z_image_turbo-Q8_0.gguf", byteSize: 6577440704, sha256: "df1c5baa86d1398c979495a6072dbcee79444fdb884a2445582ba0769c44e9a1", license: "Apache-2.0"),
            qwen3_4BTextEncoder,
            .init(id: "vae", role: "vae", repository: "Comfy-Org/z_image_turbo", revision: "6fc90a3b1b653e935a0d175e260736de25b84df5", filename: "split_files/vae/ae.safetensors", byteSize: 335304388, sha256: "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38", license: "Apache-2.0 as declared by Comfy-Org/z_image_turbo")
        ]),
        recipe(ltx23RecipeID, "LTX-2.3 dev 22B · Q4_K_M", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "unsloth/LTX-2.3-GGUF", revision: "96e8ed4925ead3db9ff4d0084f165ef6a74f28d0", filename: "ltx-2.3-22b-dev-Q4_K_M.gguf", byteSize: 14326856736, sha256: "e053e3d7827f3a69ecd00e55395d3a8f8616ab10d3a394e8d2b65ae204d490e0", license: "LTX-2 Community License Agreement"),
            .init(id: "textEncoder", role: "textEncoder", repository: "unsloth/gemma-3-12b-it-GGUF", revision: "d15e4c7dc21dc55d56bf8549db57a71ad8a2a35d", filename: "gemma-3-12b-it-Q4_K_M.gguf", byteSize: 7300778336, sha256: "15b8fd9d8672cd4240c178c217ca781409291f34e353d2e913b29c7602ceb3ff", license: "Gemma Terms of Use"),
            .init(id: "embeddingsConnectors", role: "embeddingsConnectors", repository: "unsloth/LTX-2.3-GGUF", revision: "96e8ed4925ead3db9ff4d0084f165ef6a74f28d0", filename: "text_encoders/ltx-2.3-22b-dev_embeddings_connectors.safetensors", byteSize: 2312144712, sha256: "a5c5148788d8d9d5d1e650e4cbf3502a46a2f7f975ce70c59082732c8905a8ae", license: "LTX-2 Community License Agreement"),
            .init(id: "vae", role: "vae", repository: "unsloth/LTX-2.3-GGUF", revision: "96e8ed4925ead3db9ff4d0084f165ef6a74f28d0", filename: "vae/ltx-2.3-22b-dev_video_vae.safetensors", byteSize: 1452256522, sha256: "8732bb70cf4343541815f45c9f90f5ff0519d679bd63483afc27bf79a08d3f4e", license: "LTX-2 Community License Agreement"),
            .init(id: "audioVae", role: "audioVae", repository: "unsloth/LTX-2.3-GGUF", revision: "96e8ed4925ead3db9ff4d0084f165ef6a74f28d0", filename: "vae/ltx-2.3-22b-dev_audio_vae.safetensors", byteSize: 364853140, sha256: "d7711812d9387ce940c2cd5d65a4f5a1e57bf6087cf618d89b56dd3c722c4dea", license: "LTX-2 Community License Agreement")
        ]),
        recipe(ltx25RecipeID, "LTX-2.5 dev 22B · Q4_K_M", .video, [
            .init(id: "diffusion", role: "diffusion", repository: "vantagewithai/LTX-2.5-GGUF", revision: "9a5c1bed3ff27b5e5d055fc04e3ae884381c2343", filename: "dev/ltx-2.5-22b-dev-transformer-Q4_K_M.gguf", byteSize: 15687639424, sha256: "41546ab47a8ad033b99875207cf386b062732d95fca0b4c9e124b14d4baaa378", license: "LTX-2 Community License Agreement"),
            .init(id: "textEncoder", role: "textEncoder", repository: "comfyicu/LTX-2.5", revision: "1026e00f808dbd9601911479b22d65b760737dc8", filename: "text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors", byteSize: 15372971786, sha256: "09a89e084de1a149c3de60cfe9dfd3e5161967eb09eea39e806fcdeffdd568de", license: "LTX-2 Community License Agreement"),
            .init(id: "vae", role: "vae", repository: "comfyicu/LTX-2.5", revision: "1026e00f808dbd9601911479b22d65b760737dc8", filename: "vae/ltx-2.5-video-vae-conv-bf16.safetensors", byteSize: 1452269922, sha256: "685b06ee3d9b2039647698fc4ea33175112462fc374e2777312c907897dfce8d", license: "LTX-2 Community License Agreement"),
            .init(id: "audioVae", role: "audioVae", repository: "comfyicu/LTX-2.5", revision: "1026e00f808dbd9601911479b22d65b760737dc8", filename: "vae/ltx-2.5-audio-vae-bf16.safetensors", byteSize: 364866540, sha256: "c52733d37f6a7fb7949c3dc0fb468c6cb2169e4d836983a73babb9f0d54837a5", license: "LTX-2 Community License Agreement")
        ])
    ]

    struct Profile: Sendable {
        let family: String
        let summary: String
        /// Pinned runtime documentation and metadata evidence, relative to the repository root.
        let evidence: [String]
        let notes: [String]
        /// Set when resource use is known to exceed a weights-only floor by a wide, unmeasured margin.
        let demandingReason: String?
    }

    static func profile(_ recipeID: String) -> Profile? {
        switch recipeID {
        case "sd15-q4":
            return .init(family: "Stable Diffusion 1.5", summary: "Still images from text, or a new image that starts from a connected image.", evidence: ["docs/evidence/native-model-library/README.md", "docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/sd.md"], notes: ["Older SD 1.5 quality; best near 512 × 512."], demandingReason: nil)
        case VideoCapabilityRegistry.wanT2VRecipeID:
            return .init(family: "Wan 2.1", summary: "Short low-resolution clips from text only.", evidence: ["docs/research/production-node-workflows/evidence/wan-t2v-integration.json", ".vendor/sd/source-evidence/docs/wan.md"], notes: ["The 1.3B T2V checkpoint cannot animate an image or join start/end frames."], demandingReason: nil)
        case animateDiffRecipeID:
            return .init(family: "AnimateDiff (SD 1.5)", summary: "Retained as a diagnostic recipe, but not offered by video nodes because local T2V and I2V runs produced static repeated frames.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/animatediff.md", "docs/research/model-expansion/evidence/hub/conrevo__AnimateDiff-A1111.json", "docs/research/model-expansion/evidence/proofs/animatediff-t2v-static-frame-rejection.json", "docs/research/model-expansion/evidence/proofs/animatediff-i2v-static-frame-rejection.json"], notes: ["Reuses the installed SD 1.5 checkpoint when it is already in the library.", "The pinned guide uses full-precision SD 1.5 checkpoints; this recipe pairs the motion module with Q4_0.", "Real 256×256, 8-frame T2V and I2V runs completed on this M1 Max, but each produced only one distinct decoded frame, so GenStudio withholds both paths."], demandingReason: nil)
        case lingBotRecipeID:
            return .init(family: "LingBot-Video", summary: "Text-to-video and start-image video with a 1.3B dense transformer, Qwen3-VL 4B text encoder and the Wan 2.1 VAE.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/lingbot_video.md", "docs/research/model-expansion/evidence/hub/robbyant__lingbot-video-dense-1.3b.json", "docs/research/model-expansion/evidence/hub/Qwen__Qwen3-VL-4B-Instruct-GGUF.json"], notes: ["Reuses the Wan 2.1 VAE by content identity.", "The pinned example prompt is a structured JSON caption; plain-text prompt quality is unmeasured.", "The optional Qwen3-VL vision projector is not part of this recipe, so start images are not also read by the prompt enhancer."], demandingReason: nil)
        case wan22TI2VRecipeID:
            return .init(family: "Wan 2.2", summary: "One 5B checkpoint for text-to-video and start-image video, with its own high-compression VAE.", evidence: [".vendor/sd/source-evidence/docs/wan.md", "docs/research/model-expansion/evidence/hub/QuantStack__Wan2.2-TI2V-5B-GGUF.json", "docs/research/model-expansion/evidence/hub/Comfy-Org__Wan_2.2_ComfyUI_Repackaged.json"], notes: ["Reuses the UMT5 text encoder by content identity.", "Requires the Wan 2.2 VAE; the Wan 2.1 VAE is not a substitute."], demandingReason: "5B video transformer: working memory at 704p and longer clips is well above the weight floor and unmeasured on this Mac.")
        case wan21FLFRecipeID:
            return .init(family: "Wan 2.1 FLF2V", summary: "A dedicated 14B first/last-frame checkpoint that generates motion between two connected images.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/wan.md"], notes: ["This is not the smaller Wan 2.1 text-to-video checkpoint.", "The Q4 path and command are documented but have not completed a decoded GenStudio render on this Mac."], demandingReason: "14B video transformer: generation time, activation memory and VAE peak memory are unmeasured on this Mac.")
        case minimaxH3RecipeID:
            return .init(family: "MiniMax-H3", summary: "A joint video/audio transformer with text, first-frame and first/last-frame conditioning. GenStudio's adapter keeps the video only (silent clips).", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/minimax_h3.md"], notes: ["The H3-specific Qwen3-VL-32B encoder must contain its vision tower and DeepStack mergers.", "This recipe omits the optional audio VAE, so its clips are silent; LTX-2.3 is the video route with sound.", "The exact Q4 route has not completed a decoded local proof on this Mac."], demandingReason: "About 35 GB of weights before runtime buffers; memory and speed are unmeasured on Apple Silicon.")
        case minimaxH3Ref2VARecipeID:
            return .init(family: "MiniMax-H3 Ref2VA", summary: "Reference-video editing route: conditions a new clip on ordered frames extracted from an existing video. GenStudio retains video only.", evidence: ["docs/research/production-node-workflows/evidence/sdcpp-7f410a3-docs/minimax_h3.md", "docs/research/2026-09-minimax-h3-local-assessment.md"], notes: ["Ref2VA is a separate transformer checkpoint from FL2VA; the app never substitutes one for the other.", "GenStudio extracts an ordered 24 fps PNG reference sequence and passes it with --ref-video.", "This recipe omits the audio decoder, so its clips are silent; LTX-2.3 is the video route with sound."], demandingReason: "About 35 GB of weights before runtime buffers; reference-video activation memory and speed are unmeasured on Apple Silicon.")
        case kleinRecipeID:
            return .init(family: "FLUX.2 Klein", summary: "Four-step still images from text, or edits guided by up to three ordered reference images.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/flux2.md", "docs/research/model-expansion/evidence/hub/leejet__FLUX.2-klein-4B-GGUF.json", "docs/research/model-expansion/evidence/proofs/flux2-klein-reference/klein-reference-integration.json"], notes: ["GenStudio's recommended image default on this Mac: text-to-image and the three-ordered-reference edit have each completed one decoded local render through GenStudio (14 Sep 2026), so the command path is proven end to end. The reference-edit proof used synthetic solid-colour fixtures, not real character/portrait/scene photos, so subject-identity fidelity remains unmeasured — treat output quality as experimental until you have judged it yourself. Stable Diffusion 1.5 remains available as an always-verified fallback.", "Reference editing is a separate contract from SD 1.5 image-to-image: the reference conditions the model; it is not a starting image.", "The bundled stable-diffusion.cpp build documents repeatable -r / --ref-image flags. GenStudio exposes three ordered Reference sockets for Klein only: connect a character sheet, portrait and scene reference in the intended order, then state each role in the prompt."], demandingReason: nil)
        case klein9BRecipeID:
            return .init(family: "FLUX.2 Klein 9B", summary: "A larger four-step still-image model for text prompts and edits guided by up to three ordered reference images.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/flux2.md", "docs/research/model-expansion/evidence/hub/leejet__FLUX.2-klein-9B-GGUF.json", "docs/research/model-expansion/evidence/hub/unsloth__Qwen3-8B-GGUF.json"], notes: ["Preferred quality option for character, wardrobe, environment and scene-reference experiments. The exact Q4 route is installable and resource-checked, but GenStudio has not yet completed a decoded local proof, so speed and identity fidelity remain unmeasured.", "It uses the same three ordered reference sockets and four-step command contract as Klein 4B.", "The diffusion component is covered by the FLUX Non-Commercial License. This is not an unrestricted commercial replacement for Klein 4B; review the upstream terms before production use."], demandingReason: nil)
        case zImageTurboRecipeID:
            return .init(family: "Z-Image Turbo", summary: "Eight-step still images from a written prompt, strong on photographic detail and lettering inside the picture.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/z_image.md", "docs/research/model-expansion/evidence/hub/leejet__Z-Image-Turbo-GGUF.json", "docs/research/model-expansion/evidence/hub/Comfy-Org__z_image_turbo.json"], notes: ["Apache-2.0, so images can be used commercially; FLUX.2 Klein 9B's licence is non-commercial.", "Text to image only: it does not take reference images, so use Klein for edits.", "Rated level with Klein 9B in independent blind votes. Not yet run on this Mac: your first image is the test, and its speed is recorded."], demandingReason: "6B image transformer at Q8_0 with a 4B text encoder; working memory at 1024 × 1024 is not yet measured on this Mac.")
        case juggernautXLRecipeID:
            return .init(family: "Juggernaut XL v9 (SDXL)", summary: "A single-file SDXL photographic and cinematic image model, separate from the FLUX.2 family.", evidence: ["https://huggingface.co/RunDiffusion/Juggernaut-XL-v9", "https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/sd.md"], notes: ["The publisher provides this exact SafeTensors checkpoint as the local ComfyUI/Forge/InvokeAI route. GenStudio uses its bundled Stable Diffusion checkpoint adapter and exposes its first run as an explicit test because this exact checkpoint has not yet produced a decoded image through GenStudio.", "Use it as a photographic-style comparison to Klein 9B. It accepts one connected starting image for whole-image image-to-image, not Klein's ordered multi-reference editing."], demandingReason: nil)
        case ltx23RecipeID:
            return .init(family: "LTX-2.3", summary: "Legacy GGUF 22B joint video/audio recipe documented for text-to-video, start-image and first/last-frame video.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/ltx2.md", "docs/research/model-expansion/evidence/hub/unsloth__LTX-2.3-GGUF.json"], notes: ["This stable-diffusion.cpp/GGUF recipe has no usable GenStudio adapter and cannot be installed. It is distinct from the supported native-MLX LTX-2.3 Q4 recipe.", "The pinned example uses UD-Q4_K_M and QAT Gemma files; this manifest pins the standard Q4_K_M files from the linked repositories."], demandingReason: "22B transformer plus a 12B text encoder; peak memory for 720p video is unmeasured and likely close to this Mac's limit.")
        case ltx25RecipeID:
            return .init(family: "LTX-2.5", summary: "22B joint video/audio model for text-to-video and start-image video through the bundled stable-diffusion.cpp runtime.", evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/ltx2.md", "docs/research/model-expansion/evidence/hub/comfyicu__LTX-2.5.json", "docs/research/model-expansion/evidence/hub/vantagewithai__LTX-2.5-GGUF.json"], notes: ["Uses the public comfyicu mirror for the gated upstream text encoder and conv/audio VAEs; the pinned component hashes are verified against the retained Hub metadata.", "Uses the conv video VAE; the diffusion video decoder is not supported.", "Duration must be expressed as an explicit video-frame count; temporal upscaling and auto-duration are not supported.", "The runtime generates audio, but this version of GenStudio retains validated video frames only."], demandingReason: "About 33 GB of model weights before runtime buffers; 720p generation is unmeasured and may exceed practical memory headroom on smaller Macs.")
        default:
            return nil
        }
    }
}

/// Families that were assessed but cannot be described as a complete immutable, downloadable recipe for this build.
/// These are information only: they are not ModelRecipe values and can never be passed to the installer.
struct ModelCandidate: Identifiable, Sendable {
    struct Component: Sendable, Equatable {
        let role: String
        let repository: String
        let revision: String
        let filename: String
        let byteSize: Int64
        let sha256: String
        var required: Bool = true
        let note: String
    }
    struct WorkflowUse: Sendable, Equatable {
        let task: String
        let node: String
        let status: String
    }

    let id: String
    let family: String
    let tasks: [String]
    let runtime: String
    let blockers: [String]
    let evidence: [String]
    var repositoryIDs: [String] = []
    var components: [Component] = []
    var workflowUses: [WorkflowUse] = []
    var memoryGuidance: String? = nil

    var routeDownloadBytes: Int64? {
        let required = components.filter(\.required)
        guard !required.isEmpty else { return nil }
        var total: Int64 = 0
        for component in required {
            guard component.byteSize > 0 else { return nil }
            let sum = total.addingReportingOverflow(component.byteSize)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

enum ModelCandidateCatalog {
    static let candidates: [ModelCandidate] = [
        .init(id: "hunyuanvideo-1.5", family: "HunyuanVideo 1.5", tasks: ["Text to video"], runtime: "Bundled stable-diffusion.cpp documents text-to-video only",
              blockers: ["Only text-to-video is documented at the pinned commit; the image-to-video code path is undocumented.", "The recipe choice (480p/720p, distilled, fp8-scaled support) is not established by pinned documentation.", "mradermacher/Qwen2.5-VL-7B-Instruct-GGUF declares no license.", "The documented fp16 route is about 36 GB of weights."],
              evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/hunyuan_video.md", "docs/research/model-expansion/evidence/hub/Comfy-Org__HunyuanVideo_1.5_repackaged.json"],
              repositoryIDs: ["Comfy-Org/HunyuanVideo_1.5_repackaged"]),
        .init(id: "sdxl-lightning-4step", family: "SDXL-Lightning 4-step", tasks: ["Text to image"], runtime: "Bundled stable-diffusion.cpp supports SDXL",
              blockers: ["The pinned documentation covers SDXL and SDXL-Turbo but not Lightning's step-specific sampler and timestep schedule, so GenStudio has no defensible command mapping."],
              evidence: ["docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/sd.md", "docs/research/model-expansion/evidence/hub/ByteDance__SDXL-Lightning.json"],
              repositoryIDs: ["ByteDance/SDXL-Lightning"])
    ]

    /// Curated linkage is exact and case-insensitive. Repository names and publisher prose are never guessed.
    static func candidate(forRepository repository: String) -> ModelCandidate? {
        candidates.first { candidate in
            candidate.repositoryIDs.contains { $0.caseInsensitiveCompare(repository) == .orderedSame }
        }
    }
}
