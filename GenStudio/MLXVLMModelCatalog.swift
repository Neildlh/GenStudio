import Foundation

/// Exact multitask MLX package proven on the reference M1 Max. The same
/// weights serve Local Text, Image Describer, and picture-aware Prompt Enhancer nodes.
/// Keeping this immutable recipe in the shipped catalogue prevents Start Here
/// from depending on mutable Hub metadata or recommending a family name whose
/// files differ from the package that was actually exercised.
enum MLXVLMModelCatalog {
    static let qwen38RecipeID = "mlx-vlm-3b252dd2007376aa326837983b0e41f7576b4bc45b8bff852dc40046dd6b1af7"
    static let repository = "Vontra/Qwen3.8-27B-MLX-4bit"
    static let revision = "70ae7fac63274ff2eac54152031433374cb80f2f"
    static let runtimeBuild = "Python 3.13.5 · mlx-vlm 0.7.1 · MLX 0.32.2"

    private static func component(_ id: String, _ role: String, _ filename: String, _ bytes: Int64, _ sha256: String) -> ModelComponent {
        .init(id: id, role: role, repository: repository, revision: revision, filename: filename,
              byteSize: bytes, sha256: sha256, license: "Apache-2.0")
    }

    static let qwen38: ModelRecipe = .init(
        id: qwen38RecipeID,
        // Keep the persisted recipe name stable: ModelLibrary compares the
        // complete snapshot on restart, not just the recipe identifier.
        name: "Vontra/Qwen3.8-27B-MLX-4bit · MLX VLM",
        kind: .vision,
        engineID: "mlx-vlm",
        components: [
            component("file1", "metadata", "chat_template.jinja", 8_952, "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"),
            component("file2", "config", "config.json", 4_932, "14b65a0ee06517060a6bbd979bb1a8ff54e7b304b1a1f01d54344b88b8285e85"),
            component("file3", "metadata", "generation_config.json", 202, "e70c136c1b78ddc1fb0905bac8e733a4dc448d4f852a5dd75143fffc70be550e"),
            component("file4", "weights", "model-00001-of-00003.safetensors", 5_343_268_662, "6cc1508e96fb5d0865dfd5753a79f4ec60651bf3e2a82844a7e8ae9c60528c0d"),
            component("file5", "weights", "model-00002-of-00003.safetensors", 5_354_185_130, "83f2a20ca8058f486a3634a27faf99587f4cd3c156a83dee34fb99e6ac178670"),
            component("file6", "weights", "model-00003-of-00003.safetensors", 5_357_087_557, "31b8c91ef899f79efaaa69e3d2c096f6e2ebeb2ff20e29222abbd9ebc79e560a"),
            component("file7", "metadata", "model.safetensors.index.json", 218_281, "13b840162b4cb35c66fef7df072f7dbb4717908204364f5e5d9f9655a2758fa8"),
            component("file8", "metadata", "preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
            component("file9", "metadata", "processor_config.json", 991, "45fc17c8dd2474af6b493b52483c26c0584b0082d368c480f9fa611e73070040"),
            component("file10", "metadata", "tokenizer.json", 19_989_325, "06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523"),
            component("file11", "metadata", "tokenizer_config.json", 1_165, "792fa3f0cb88b111e54ef3134c873531008c4df471d108da17903426e308aa7b")
        ],
        runtimeReady: false,
        minimumMemoryBytes: 22_517_216_531,
        runtimeProfile: "mlx-vlm",
        provider: "huggingface",
        sourceURL: URL(string: "https://huggingface.co/\(repository)"),
        workflowCapabilities: [.textGeneration, .imageUnderstanding]
    )

    static let recipes = [qwen38]
    static func supportsRecipe(_ id: String) -> Bool { id == qwen38RecipeID }
}
