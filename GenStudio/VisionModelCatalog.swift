import Foundation

/// Exact model/projector pairs verified against Hub metadata on 2026-09-13.
/// Architectures are listed by llama.cpp b7100/c49daff5b's multimodal documentation.
/// runtimeReady indicates an integrated adapter path, not measured speed or inference proof.
enum VisionModelCatalog {
    /// Only SmolVLM has completed a decoded local task in the shipped
    /// llama.cpp-vision path. Larger GGUF recipes remain explicit benchmark
    /// candidates until they produce retained output on the reference Mac.
    static func supportsRecipe(_ id: String) -> Bool { id == "vision-smolvlm-500m-q8" }

    static func purpose(_ id: String) -> String {
        switch id {
        case "vision-smolvlm-500m-q8": "Small download for testing local image descriptions and simple visual questions. Limited detail and instruction following; not the premium choice."
        case "vision-qwen25vl-7b-q4km": "Practical candidate for photographic descriptions, composition, visible objects and text. Compare its output with your reference image."
        case "vision-qwen25vl-32b-q4km": "Larger, demanding candidate for detailed visual analysis. Evaluate whether its additional detail justifies the memory and waiting time."
        default: "Local image understanding with a matching model and vision projector."
        }
    }
    static func limits(_ id: String) -> String {
        if id == "vision-smolvlm-500m-q8" {
            return "Local M1 Max test: about 11 seconds for each simple single-image color answer. It missed shape details and failed a two-image comparison. Use this model to test the connection; choose a larger model for campaign analysis."
        }
        let demand = id == "vision-qwen25vl-32b-q4km" ? "Large memory demand; keep other heavy jobs idle. " : ""
        return demand + "Exact recipe unbenchmarked on this Mac. Speed and descriptive accuracy are unverified; visible details may be missed or invented. Produces text, not images."
    }
    static let recipes: [ModelRecipe] = [
        .init(id: "vision-smolvlm-500m-q8", name: "SmolVLM 500M · Q8 · lightweight vision", kind: .vision, engineID: "llama.cpp-vision", components: [
            .init(id: "model", role: "model", repository: "ggml-org/SmolVLM-500M-Instruct-GGUF", revision: "72e986006ef53e37cdd3f6d4241c90b0f01df376", filename: "SmolVLM-500M-Instruct-Q8_0.gguf", byteSize: 436806912, sha256: "9d4612de6a42214499e301494a3ecc2be0abdd9de44e663bda63f1152fad1bf4", license: "Apache-2.0"),
            .init(id: "mmproj", role: "mmproj", repository: "ggml-org/SmolVLM-500M-Instruct-GGUF", revision: "72e986006ef53e37cdd3f6d4241c90b0f01df376", filename: "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf", byteSize: 108783360, sha256: "d1eb8b6b23979205fdf63703ed10f788131a3f812c7b1f72e0119d5d81295150", license: "Apache-2.0")
        ], runtimeReady: true, minimumMemoryBytes: 4 * 1024 * 1024 * 1024),
        .init(id: "vision-qwen25vl-7b-q4km", name: "Qwen 2.5 VL 7B · Q4 · detailed vision", kind: .vision, engineID: "llama.cpp-vision", components: [
            .init(id: "model", role: "model", repository: "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF", revision: "508edd0afaa66bb9e9f40587acc2184f02daf1f6", filename: "Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", byteSize: 4683072032, sha256: "9258bf05b12686d097ff3b6b18d968ab393649780aa2b3cd67fec43d50554392", license: "Apache-2.0"),
            .init(id: "mmproj", role: "mmproj", repository: "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF", revision: "508edd0afaa66bb9e9f40587acc2184f02daf1f6", filename: "mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf", byteSize: 853119712, sha256: "2ddb555391bae966e412deab9e07b58afa18bcc06930ba0f1c78a3695ab9e506", license: "Apache-2.0")
        ], runtimeReady: true, minimumMemoryBytes: 12 * 1024 * 1024 * 1024),
        .init(id: "vision-qwen25vl-32b-q4km", name: "Qwen 2.5 VL 32B · Q4 · demanding vision", kind: .vision, engineID: "llama.cpp-vision", components: [
            .init(id: "model", role: "model", repository: "ggml-org/Qwen2.5-VL-32B-Instruct-GGUF", revision: "94e4f98b5df15a6198401ad1dce38897b38c41a6", filename: "Qwen2.5-VL-32B-Instruct-Q4_K_M.gguf", byteSize: 19851334528, sha256: "96e905b5d39809a9c6bf01890222ac8ebd3d77deec59e2a4fee5c88d630a0822", license: "Apache-2.0"),
            .init(id: "mmproj", role: "mmproj", repository: "ggml-org/Qwen2.5-VL-32B-Instruct-GGUF", revision: "94e4f98b5df15a6198401ad1dce38897b38c41a6", filename: "mmproj-Qwen2.5-VL-32B-Instruct-Q8_0.gguf", byteSize: 734862208, sha256: "31ae8d7bda4ec9209f6878200a8a02cf0aeb6a4bfe81a1965680674b915fa328", license: "Apache-2.0")
        ], runtimeReady: true, minimumMemoryBytes: 32 * 1024 * 1024 * 1024)
    ]
}
