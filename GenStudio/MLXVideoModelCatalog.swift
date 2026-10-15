import Foundation

/// Immutable MLX video manifests. These stay separate from the legacy
/// stable-diffusion.cpp catalogue because their directory trees, runtime build,
/// and task contract must be validated as one package.
enum MLXVideoModelCatalog {
    static let fastMetal5BRecipeID = "mlx-fastmetal-5b-qad"
    static let fastVideoBuild = "FastVideo@c4824c776433555ab655a0dfc43c25f4dac20829"
    static let ltx23Q4RecipeID = "mlx-ltx-23-q4"
    static let ltxBuild = "ltx-2-mlx@ae3b7ea9583db775bd4a1dfb506fb789585021e7"
    private static let repository = "FastVideo/FastMetal-5B-QAD"
    private static let revision = "5e4819ec9c8dd062443cf015bd9022c700eca458"
    private static let license = "Apache-2.0"

    private static func component(_ id: String, _ role: String, _ filename: String, _ bytes: Int64, _ sha256: String) -> ModelComponent {
        .init(id: id, role: role, repository: repository, revision: revision, filename: filename, byteSize: bytes, sha256: sha256, license: license)
    }

    /// Complete public FastMetal-5B-QAD package as read from the Hugging Face
    /// model API on 17 Sep 2026. Git metadata/README are omitted; all runtime
    /// weights, tokenizer files, and configs are SHA-256 pinned.
    static let fastMetal5B: ModelRecipe = .init(
        id: fastMetal5BRecipeID, name: "FastMetal 5B QAD · MLX (Apple Silicon T2V)", kind: .video, engineID: "mlx-fastvideo", components: [
            component("mlxConfig", "mlxConfig", "mlx_dit.json", 31_940, "5a81c62200a949d9fa2b277f16d47c5793c3b31defb7b5c058e9fe82ed0b6d5a"),
            component("mlxDiT", "mlxDiT", "mlx_dit.safetensors", 5_314_678_720, "652c322e954046dfea2fe5e5e239c2284ee5d8bcd18d40ed57d9c6cdf95b930a"),
            component("modelIndex", "metadata", "model_index.json", 502, "a43fbeeb223895748ee9b266f52c0272ad31e6be3eb664d22dfc097015134ab9"),
            component("scheduler", "metadata", "scheduler/scheduler_config.json", 820, "571a3eed68bcd943a61b9fea8efa9e141472216ada59f928c8b5128ce24b32e0"),
            component("textConfig", "textEncoder", "text_encoder/config.json", 855, "a2bcb24699f6c009a2427432bdd483ef8b2b42a712abc9503759cdc77d171f07"),
            component("textShard1", "textEncoder", "text_encoder/model-00001-of-00003.safetensors", 4_935_812_536, "a8e861969c7433e707cc5a74065d795d36cca07ec96eb6763eb4083df7248f58"),
            component("textShard2", "textEncoder", "text_encoder/model-00002-of-00003.safetensors", 4_983_103_192, "d57d948ece4837d850b7a859a4415121d57cacf8b9ee1d4db200c67f592902d7"),
            component("textShard3", "textEncoder", "text_encoder/model-00003-of-00003.safetensors", 1_442_935_480, "0da9ee284e21d1406df708788db1d502d95d75f69faa25cd26151bf8829b7c5f"),
            component("textIndex", "textEncoder", "text_encoder/model.safetensors.index.json", 22_476, "31c4c7bcce679eaa0dd4667462394ddb013dc2f748e0bffc893dc9146a320dab"),
            component("tokenSpecial", "tokenizer", "tokenizer/special_tokens_map.json", 7_079, "456b58fd240a06c743a7c2cf8008bec501240d68ebd1fc4018ea569505fea270"),
            component("tokenModel", "tokenizer", "tokenizer/spiece.model", 4_548_313, "e3909a67b780650b35cf529ac782ad2b6b26e6d1f849d3fbb6a872905f452458"),
            component("tokenJSON", "tokenizer", "tokenizer/tokenizer.json", 16_837_459, "20a46ac256746594ed7e1e3ef733b83fbc5a6f0922aa7480eda961743de080ef"),
            component("tokenConfig", "tokenizer", "tokenizer/tokenizer_config.json", 61_758, "1d8d2a216bf8e70ac15b7ddcea566c4dd0433c024b39a58ca5e4c66bd78defbd"),
            component("vaeConfig", "vae", "vae/config.json", 1_701, "d996c340fe9a7df5d7371f76a7d8d6956f6c98256080074d8434fa5eeac11360"),
            component("vae", "vae", "vae/diffusion_pytorch_model.safetensors", 2_818_777_808, "62cd18f19438e35b32ac63020e2852f566e9b02f46b6cdbd87972a356e3c6f4b")
        ], runtimeReady: false, minimumMemoryBytes: 48 * 1024 * 1024 * 1024,
        runtimeProfile: "mlx-fastvideo", provider: "huggingface", sourceURL: URL(string: "https://huggingface.co/FastVideo/FastMetal-5B-QAD")
    )

    private static let ltxRepository = "dgrauet/ltx-2.3-mlx-q4"
    private static let ltxRevision = "56a5866d638ecfe37c54d348e88938235185c2d4"
    private static let gemmaRepository = "mlx-community/gemma-3-12b-it-4bit"
    private static let gemmaRevision = "86cc6a8dedbc456dd0e4af01a9d09f396f77e558"

    private static func ltxComponent(_ id: String, _ role: String, _ filename: String, _ bytes: Int64, _ sha256: String) -> ModelComponent {
        .init(id: id, role: role, repository: ltxRepository, revision: ltxRevision, filename: filename, byteSize: bytes, sha256: sha256, license: "LTX-2 Community License Agreement")
    }

    private static func gemmaComponent(_ id: String, _ role: String, _ sourceFilename: String, _ bytes: Int64, _ sha256: String) -> ModelComponent {
        .init(id: id, role: role, repository: gemmaRepository, revision: gemmaRevision,
              filename: "gemma/\(sourceFilename)", byteSize: bytes, sha256: sha256,
              license: "Gemma Terms of Use", sourceFilename: sourceFilename)
    }

    /// The original video-only package: dgrauet's maintained LTX-2.3 Q4 MLX distilled two-stage
    /// pipeline without its sound decoder. Packages installed before 12 Oct 2026 have exactly this
    /// shape and keep working (silently); `ModelLibrary.extendInstalledPackage` adds the sound files.
    static let ltx23Q4Silent: ModelRecipe = .init(
        id: ltx23Q4RecipeID, name: "LTX-2.3 MLX Q4 · Apple Silicon T2V + I2V", kind: .video, engineID: "mlx-ltx", components: [
            ltxComponent("ltxConfig", "ltxConfig", "config.json", 951, "2dd64d4f8b7a385b0471a23a6e2069e4bc0f9d9903fc289347b2e4cac3c776ec"),
            ltxComponent("embeddedConfig", "ltxConfig", "embedded_config.json", 7_234, "c09755357e21d2b2eb15ea2b5c3c11f1e6b44c514ebb6d8babeee30e86f7bd14"),
            ltxComponent("quantizeConfig", "ltxConfig", "quantize_config.json", 100, "473aec38f34570fe7379d337e00fa191240cd9578da17df1f55df247b735012f"),
            ltxComponent("splitModel", "ltxConfig", "split_model.json", 1_835, "bb72acf615558c11578b677ede6b530481c3e09db0d36515239dd8c95704ea04"),
            ltxComponent("transformer", "ltxTransformer", "transformer-distilled-1.1.safetensors", 11_322_002_285, "a78f67e1c9bf3c171b8c043721cdb7cbf72ff2a1fc8a5021769ca622f506b890"),
            ltxComponent("connector", "textConnector", "connector.safetensors", 6_344_495_512, "5885c2bd7af4e761b3257cf5b17bc1fdb2d187cea3ca520ea723b6a129b7029f"),
            ltxComponent("vaeEncoder", "vaeEncoder", "vae_encoder.safetensors", 637_885_319, "1512f5ef8387901db0baecb328690676e2667ddf2b63e28f8e6645188c1a8c06"),
            ltxComponent("vaeDecoder", "vaeDecoder", "vae_decoder.safetensors", 814_349_531, "f404026fe0b59418eaec4a3fcdc474125c798f0b787dc390f6eb4e79934d4160"),
            ltxComponent("upscalerConfig", "upscaler", "spatial_upscaler_x2_v1_1_config.json", 275, "c0646d97bf1bc3fa6e66ec7d17f16ef31b717e64bf86474b7dc3993b6c42346a"),
            ltxComponent("upscaler", "upscaler", "spatial_upscaler_x2_v1_1.safetensors", 995_745_061, "755f69dcb8a3f9589045925eb4a2237e9969f9c026a016393bc395e65ebd5788"),
            gemmaComponent("gemmaAddedTokens", "tokenizer", "added_tokens.json", 35, "50b2f405ba56a26d4913fd772089992252d7f942123cc0a034d96424221ba946"),
            gemmaComponent("gemmaChatTemplate", "tokenizer", "chat_template.json", 1_615, "fe16baf728db49457cde32802cd7efc0ac8a7a9877dbe22fe3322b2d9dc6ccd9"),
            gemmaComponent("gemmaConfig", "textEncoder", "config.json", 1_141, "73ed96a3f1d596fcf3c07f17ed7e4358fd99be688c97da45f2464fd48dd069ed"),
            gemmaComponent("gemmaGenerationConfig", "textEncoder", "generation_config.json", 192, "e04ecb65db447404710114fb282baaac482d22a95e2244ecaab428b81672ba78"),
            gemmaComponent("gemmaShard1", "textEncoder", "model-00001-of-00002.safetensors", 5_367_455_313, "995cbd05b7bfd8f5ab5307b476eb5496b5ec3f5256a9dd26366236ce8816c93f"),
            gemmaComponent("gemmaShard2", "textEncoder", "model-00002-of-00002.safetensors", 2_661_219_935, "8b7af7eb5ff32109fc65cbcd0af5b8016ac0de46df17f40705f043f899495333"),
            gemmaComponent("gemmaIndex", "textEncoder", "model.safetensors.index.json", 108_605, "788cc42a1a92835df62d9a3791f47105f63504c7c404637a73288e9b11bc7b82"),
            gemmaComponent("gemmaPreprocessor", "tokenizer", "preprocessor_config.json", 570, "f688d6bb20c5017601c4011de7ca656da8485b540b05013efdaf986c0fcc918d"),
            gemmaComponent("gemmaSpecialTokens", "tokenizer", "special_tokens_map.json", 662, "2f7b0adf4fb469770bb1490e3e35df87b1dc578246c5e7e6fc76ecf33213a397"),
            gemmaComponent("gemmaTokenizerJSON", "tokenizer", "tokenizer.json", 33_384_568, "4667f2089529e8e7657cfb6d1c19910ae71ff5f28aa7ab2ff2763330affad795"),
            gemmaComponent("gemmaTokenizerModel", "tokenizer", "tokenizer.model", 4_689_074, "1299c11d7cf632ef3b4e11937501358ada021bbdf7c47638d13c0ee982f2e79c"),
            gemmaComponent("gemmaTokenizerConfig", "tokenizer", "tokenizer_config.json", 1_157_007, "0d95398b39395e5cfb290683a78f3fb0551223c672d8b033333c1a5307473760")
        ], runtimeReady: false, minimumMemoryBytes: 32 * 1024 * 1024 * 1024,
        runtimeProfile: "mlx-ltx", provider: "huggingface", sourceURL: URL(string: "https://huggingface.co/dgrauet/ltx-2.3-mlx-q4")
    )

    /// LTX-2.3's transformer denoises sound jointly with the picture; these decode it (audio VAE →
    /// BigVGAN vocoder → 48 kHz). Read from the pinned revision's Hugging Face tree on 12 Oct 2026.
    static let ltx23SoundComponents: [ModelComponent] = [
        ltxComponent("audioVAE", "audioDecoder", "audio_vae.safetensors", 106_509_048, "442119db8eaf976f83a105cc8c5f2c930e0f625062f9776b10adcdb7bc96c416"),
        ltxComponent("vocoder", "vocoder", "vocoder.safetensors", 258_313_851, "410cee86c14f76956bf487d153211ef15050fe8bf51f86d47a1d27ca6e3ba287")
    ]

    /// The complete package GenStudio installs: the video weights plus the sound decoder. Optional
    /// dev transformer and LoRA packs stay excluded.
    static let ltx23Q4: ModelRecipe = .init(
        id: ltx23Q4Silent.id, name: ltx23Q4Silent.name, kind: ltx23Q4Silent.kind, engineID: ltx23Q4Silent.engineID,
        components: ltx23Q4Silent.components + ltx23SoundComponents, runtimeReady: ltx23Q4Silent.runtimeReady,
        minimumMemoryBytes: ltx23Q4Silent.minimumMemoryBytes, runtimeProfile: ltx23Q4Silent.runtimeProfile,
        provider: ltx23Q4Silent.provider, sourceURL: ltx23Q4Silent.sourceURL
    )

    static func isLTX23Package(_ recipe: ModelRecipe?) -> Bool { recipe == ltx23Q4 || recipe == ltx23Q4Silent }
    static func hasSound(_ recipe: ModelRecipe?) -> Bool { recipe == ltx23Q4 }

    /// The silent package stays in the catalog so the library accepts installs made before sound.
    static let recipes = [fastMetal5B, ltx23Q4]
    static let supersededRecipes = [ltx23Q4Silent]
}
