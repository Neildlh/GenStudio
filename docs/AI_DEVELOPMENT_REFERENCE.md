# GenStudio AI development reference

This is the portable context to give an AI model before asking it to diagnose, design, or change GenStudio. It is deliberately concise enough to paste, while linking to the repository for details.

## Copy-ready context

```text
You are working on GenStudio, a native Swift 6 macOS 26 application for Apple Silicon. It is a local-first visual AI workflow studio: users connect typed, named nodes to turn prompts and source media into text, images, short video, deterministic edits, and exports. The app owns its local execution path through app-managed llama.cpp and stable-diffusion.cpp command-line engines, a self-contained pinned MLX runtime, and RifeMetal; it is not a wrapper around Draw Things, ComfyUI, Ollama, Homebrew Python, or a hosted backend. Debug app bundles omit the heavy runtime: Models → Start Here installs it atomically once at `~/Library/Application Support/GenStudio/RuntimeLibrary/Installed/native-2026-10-12`. Release bundles the signed runtime under `Contents/Resources/LocalRuntimes`.

The Xcode app target is the GenStudio/ directory and depends only on RifeMetal 0.1.6. EngineKit and ProviderKit are separate Swift packages and are not linked into the app. HeliosGen is credited as inspiration but its source is not included here. Models are not bundled: the running app uses ~/Library/Application Support/GenStudio/ModelLibrary and stores projects/runs/outputs/artifacts under the same GenStudio Application Support root.

Before answering, inspect current source, project.yml, scripts, and tests. Then read docs/PRODUCT.md, docs/PRD.md, docs/ARCHITECTURE.md, and docs/INFRASTRUCTURE.md. Treat dated research and plans as evidence/history, not current implementation truth. Capability registries in ImageCapabilities.swift, VideoTasks.swift, UpscaleCapabilities.swift, ModelCatalog.swift, MediaModelCatalog.swift, MLXVLMModelCatalog.swift, MLXVideoModelCatalog.swift, and VisionModelCatalog.swift are authoritative for exact recipe/task readiness. Keep model recipe, backend/build and task capability/readiness separate. FastMetal is integrated T2V-only, is the fast draft engine (launcher-measured on the M1 Max), and offers an opt-in interpolated fast draft. LTX-2.3 Q4 is integrated through native MLX for exact T2V and I2V tasks and remains awaiting per-task decoded proof; its old CPU-offloaded route is unavailable.

Preserve these invariants: local-first execution with no silent cloud fallback; typed named ports and ordered repeatable inputs; output fan-out and acyclic graphs; explicit recipe/engine/task compatibility; atomic persistence and schema compatibility; cancellation and interrupted-run recovery; validated retained media and provenance; no model weights bundled; no API keys in logs/exports. A green build or process exit is not a model/media proof. Run the relevant tests and report skipped opt-in integration tests honestly.
```

## Source precedence

When information conflicts, use:

1. current `GenStudio/` source, `project.yml`, `script/`, and tests;
2. `docs/PRODUCT.md` for product invariants;
3. `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/INFRASTRUCTURE.md`, and `docs/PACKAGING.md`;
4. the named capability evidence retained in current source/tests;
5. plans and old notes only as historical context when present.

Do not infer that a feature is shipped from a plan or test fixture. Confirm the app target in `project.yml`. If a claim concerns an exact model, inspect its registry readiness and named evidence.

## Question routing

| Question | Read first |
|---|---|
| What is the app for? | `docs/PRODUCT.md`, `docs/PRD.md` |
| How does a workflow run? | `docs/ARCHITECTURE.md`, `Execution.swift`, `RunPlanning.swift` |
| Why is a model unavailable? | capability registries, `ModelCompatibility.swift`, `VideoPreflight.swift` |
| Where are files/models saved? | `Persistence.swift`, `StudioModel.swift`, `ModelLibraryCore.swift` |
| Why did a native process fail? | `LocalRuntimeLibrary.swift`, `NativeGenerationEngine.swift`, `NativeVideoEngine.swift`, `ManagedMLXRuntime.swift`, `MLXFastVideoEngine.swift`, `script/package_local_runtimes.sh`, `.vendor/*/MANIFEST.md` |
| How does model download work? | `ModelDiscovery.swift`, `ModelLibraryCore.swift`, `ResumableDownload.swift` |
| How do I change a node? | `Domain.swift`, `GraphValidator.swift`, the matching inspector/engine, and node tests |
| How do I ship it? | `project.yml`, `script/package_local_runtimes.sh`, `docs/PACKAGING.md` |
| Is cloud integrated? | `project.yml`, app imports, `ProviderKit`, `docs/PRODUCT.md` |
| Is a feature really proven? | exact capability readiness plus its referenced proof; then current integration tests |

## Implementation map

- UI/composition: `AppAndViews.swift`, `StudioModel.swift`, inspector and model-library views.
- Domain: `Domain.swift` (`NodeKind`, ports, values, workflow schema, runs, artifacts).
- Validation/planning: `GraphValidator.swift`, `RunPlanning.swift`, `RecipeFit.swift`.
- Execution: `Execution.swift`, `NativeGenerationEngine.swift`, `NativeVisionEngine.swift`, `ManagedMLXRuntime.swift`, `MLXVLMRuntime.swift`, `NativeVideoEngine.swift`, `MLXFastVideoEngine.swift`, `VideoExecution.swift`.
- Media: `MediaProcessing.swift`, `VideoAssembly.swift`, `VideoEncoding.swift`, `VideoFinishing.swift`, `VideoUpscaleExecution.swift`.
- Model library: `ModelCatalog.swift`, `MLXVLMModelCatalog.swift`, `MLXVideoModelCatalog.swift`, `ModelDiscovery.swift`, `ModelLibraryCore.swift`, `ModelLibraryUpdates.swift`, `ResumableDownload.swift`.
- Local runtime: `LocalRuntimeLibrary.swift`, `ManagedMLXRuntime.swift`, `ModelLibraryViewModel.swift`, `script/install_local_runtime.sh`.
- Capability contracts: `ImageCapabilities.swift`, `VideoTasks.swift`, `UpscaleCapabilities.swift`, `ModelCompatibility.swift`.
- Persistence: `Persistence.swift`, `GenerationTakes.swift`, and the lifecycle tests.

## Safe change protocol

1. Identify the user-visible contract and the exact node/task/model path.
2. Inspect the source of truth and adjacent tests before editing.
3. Keep UI state on `@MainActor`; keep execution, persistence, and library work actor-isolated/off the UI path.
4. Extend explicit capability/command registries instead of accepting arbitrary model files by extension.
5. Preserve provenance, validation, cancellation, atomic writes, and recovery behavior.
6. Update the relevant canonical documentation if architecture, product scope, infrastructure, or packaging changed. For runtime or build behavior, reconcile `README.md`, `PRODUCT.md`, `PRD.md`, `ARCHITECTURE.md`, `INFRASTRUCTURE.md`, `PACKAGING.md`, and this document against `project.yml` and `script/`.
7. Regenerate XcodeGen after `project.yml` edits.
8. Run the narrow tests first, then the app suite and affected Swift package suite.
9. For native/model changes, run or document a real decoded-media proof; distinguish it from a fixture/unit test.

## Verification commands

```bash
xcodegen generate --spec project.yml
xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages test
swift test --package-path EngineKit
swift test --package-path ProviderKit
```

Use `script/build_and_run.sh verify` for a launch smoke check, `logs` for process logs, and `telemetry` for the app's telemetry subsystem. Opt-in real-model tests document their own environment variables; skipped tests are not failures, but they are not proofs.

## Known current boundaries

- ProviderKit clients exist but cloud nodes are not integrated into the app.
- EngineKit exists but the app has its own model-library implementation and does not import EngineKit.
- Public Hugging Face discovery/download works; gated/private downloads do not because credentials are not sent.
- Some image/video recipes are experimental or awaiting proof; AnimateDiff is explicitly rejected after identical-frame output.
- Start Here’s Set Up Working Core first ensures the app-owned local runtime is installed, then queues Qwen3.8-27B MLX 4-bit, FLUX.2 Klein 9B, FastMetal 5B, LTX-2.3 MLX Q4 and Real-ESRGAN x4plus (`starterRecipes` in `ModelLibraryViewModel.swift`); normal search is proof-gated. Proof is a label, not a permission: only `.unavailable` capabilities are blocked (see `docs/LOCAL_WEAVE_ROADMAP.md`).
- FastMetal is app-integrated and T2V-only. Launcher-measured on this M1 Max on 12 Oct 2026 (832×480 5 s clip in 88 s, 46 s as a fast draft; 1280×704 in 319 s); its capability stays `awaitingProof` until the first decoded graph run records it.
- LTX-2.3 Q4 also has a start/end-frame capability (start image at frame 0, end image at `last`); launcher-measured 186 s for a 5 s 768×448 clip, about 8× faster than MiniMax-H3 FL2VA here.
- LTX-2.3 Q4 has a typed `mlx-ltx` T2V/I2V backend and complete pinned LTX, Gemma, VAE and upscaler recipe. Do not treat installation as proof; only a decoded graph run verifies the corresponding task.
- The old LTX CPU-offloaded stable-diffusion.cpp route is unavailable and must never be used as fallback.
- `.vendor/mlx-fastvideo` is the pinned development source for a self-contained Python 3.13.5 runtime shared by Qwen, FastMetal and LTX through separate launchers. `LocalRuntimeLibrary` verifies the installed shape; Debug resolves that installation and Release resolves its bundled resource first. There is no system/Homebrew/user-site fallback.
- Guided Shot is authorable but unavailable until native multi-anchor execution is proven.
- Some video adapters generate audio that the current retained video contract discards.
- App Sandbox is disabled; Release Hardened Runtime is configured, but Developer ID/notarization is not verified.
- `.vendor/sd/models` contains development weights but packaging copies only native runtime binaries/libraries/licences.

## How to report an answer

State whether the answer is based on current code, a documented product invariant, or historical evidence. Name the files inspected. For a proposed change, describe the affected node/task, persistence or compatibility implications, tests to run, and any proof or credentials still required. Never call a future boundary “already supported” merely because a helper or package exists.
