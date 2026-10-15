# Bundled native model adapters: 2026-09-13

Implemented app adapters in `GenStudio/NativeGenerationEngine.swift` and resource packaging in `script/package_local_runtimes.sh`. The app's normal engine is now the direct bundled llama.cpp adapter; SD 1.5 uses the bundled stable-diffusion.cpp adapter. Runtime paths resolve from `Bundle.main.resourceURL/LocalRuntimes`, never the development workspace. Supporting dylibs and licenses are copied and nested executables signed before the app is signed. The bundled releases require Apple silicon and macOS 26.

## Verification

- Actual GenStudio target built with new source and packaged runtimes in `.build/NativeAdapterBuild/Build/Products/Debug/GenStudio.app`.
- `codesign --verify --deep --strict` passed for that application.
- Native focused XCTest run: three passed, one opt-in real-model XCTest skipped, zero failures. `.build/native-adapter-tests.log` contains the run. Tests cover cancellation/reaping/next-job, timeout, bounded output draining, and rejecting connected reference images before model load.
- Real inference was verified separately by compiling the actual ModelCatalog, ModelLibraryCore and NativeGenerationEngine sources into the included command-line proof harness. `standalone-protocol-stubs.swift` provides only the existing app's protocol/value/error declarations needed to compile outside the GUI target; generation and library code are the production sources.
- Harness ran using **executables and libraries inside the successfully built app bundle**, with `/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)'`. No model download occurred. Existing exact Qwen and SD files were copied into a fresh library, fully checked by the normal import API, and revalidated before generation.
- Qwen returned `LOCAL_READY`; SD generated the attached valid 512×512 PNG at 20 steps, seed 424242; reopening the library returned `RESTART_READY`. Both records were marked inference-verified only after success. `offline-adapter.log` records loading, running and unloaded events from the actual adapter. Inspection of `image.png` shows a coherent red apple on a red/dark background; it did not closely match the requested dark table, so this is runtime proof rather than a prompt-fidelity claim.
- `new-process-offline-restart.log` is a separate fresh executable invocation under the same network-denial profile using the already installed library. This distinguishes new-process persistence from merely reopening the actor.

The first proof attempt detected a trailing-directory-slash ownership comparison defect in the library. It was repaired by the core author and the successful proof above uses a distinct fresh library (`.build/native-offline-proof2`). The earlier `.build/native-offline-proof.log` is historical failing evidence, not the final result.

## Deliberate limits

Only exact verified Qwen 2.5 0.5B and SD 1.5 recipes execute. SD runs text-to-image only (reference connections are explicitly rejected), 256–768 pixel dimensions in multiples of 64, fixed 20 steps, unsigned 32-bit seed. There is no cloud fallback or service to start. Process exit releases runtime resources; no persistent ready model is claimed. The shared ExecutionQueue serializes normal workflow inference. Native runner timeout is 600 seconds for images and the text caller's timeout; cancellation sends SIGTERM, escalates after two seconds, reaps the process, and continuously drains both output streams with bounded retained logs.

Full GUI selection/download wiring acceptance remains the parent task's responsibility. These proofs do not claim a live GUI generation click or universal Hugging Face compatibility.
