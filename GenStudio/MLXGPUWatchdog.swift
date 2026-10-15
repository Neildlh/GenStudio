import Foundation

/// macOS 26/27 can stop long MLX GPU work while the display is busy
/// (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`, mlx#3267). That failure says nothing about the
/// take, so the MLX video engines retry it once; any other failure is reported exactly as it happened.
enum MLXGPUWatchdog {
    static let signature = "kIOGPUCommandBufferCallbackErrorImpactingInteractivity"
    static let retryNote = "[note] The macOS GPU watchdog stopped the first attempt (display activity during a long MLX job). GenStudio retried once automatically. Letting the display sleep during long batches avoids it."

    static func shouldRetry(status: Int32, output: String, attempt: Int) -> Bool {
        status != 0 && attempt == 1 && output.contains(signature)
    }

    /// Runs `launch`, and once more if the first attempt was stopped by the watchdog.
    static func run(isolation: isolated (any Actor)? = #isolation, _ launch: () async throws -> NativeProcessResult) async throws -> (result: NativeProcessResult, retried: Bool) {
        let first = try await launch()
        guard shouldRetry(status: first.status, output: first.stdout + "\n" + first.stderr, attempt: 1) else { return (first, false) }
        try Task.checkCancellation()
        GenerationProgressContext.report?(.init(stage: "Retrying after a macOS GPU interruption"))
        return (try await launch(), true)
    }
}
