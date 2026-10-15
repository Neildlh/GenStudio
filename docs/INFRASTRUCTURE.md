# GenStudio infrastructure and operations

Status: implemented infrastructure audit
Last reviewed: 18 September 2026

## Runtime topology

GenStudio is a desktop-only, single-process product with local child processes for native inference. It has no backend, hosted database, message queue, remote worker, user account service, or required cloud inference API. MLX model families may use an app-owned isolated child-process runtime; its dependencies and source revisions must be pinned, packaged and signed like the existing native runtimes.

```text
Mac app bundle
├── SwiftUI/AppKit executable
├── RifeMetal package code
└── Resources/LocalRuntimes (signed Release fallback; omitted from Debug)
    ├── llama/bin/{llama-cli,llama-mtmd-cli}
    ├── llama/lib/*.dylib + licences
    ├── sd/bin/sd-cli + lib/*.dylib + licences
    └── mlx-fastvideo/
        ├── lib/Python.framework (relocated arm64 Python 3.13.5)
        ├── pinned site-packages + FastVideo and ltx-2-mlx source
        ├── bin/{genstudio-mlx-vlm,genstudio-fastmetal-5b,genstudio-ltx-23,genstudio-mlx-tts,ffmpeg}
        ├── share/genstudio-aux (FastMetal's TAEHV decoder + RIFE 4.25 interpolator, ~45 MB, MIT; see MANIFEST)
        └── requirements.lock + RUNTIME.lock

User data: ~/Library/Application Support/GenStudio
├── RuntimeLibrary/Installed/native-2026-10-12 (one-time Debug runtime)
└── projects, runs, outputs, artifacts, ModelLibrary, scratch
```

## Toolchain and build graph

`project.yml` is the XcodeGen source of truth:

- app: `studio.gen.GenStudio`;
- Swift 6 with complete strict concurrency;
- macOS deployment target 26.0;
- app version 0.1.0 / build 1;
- dependency: RifeMetal exactly 0.1.6 from GitHub;
- App Sandbox disabled;
- Debug unhardened, Release Hardened Runtime enabled;
- Xcode user-script sandboxing disabled because the packaging script recursively copies and signs nested runtime code.

`xcodegen generate --spec project.yml` produces `GenStudio.xcodeproj`. The `GenStudio` target compiles `GenStudio/`; `GenStudioTests` depends on the app target. `script/build_and_run.sh` regenerates only when `project.yml` or the Swift source-file list changes, keeps one canonical DerivedData directory, and shares package checkouts through `.build/SourcePackages`. Xcode resolves RifeMetal and its Swift Argument Parser dependency there instead of cloning them into every scratch DerivedData directory.

Supporting packages are independent:

| Package | Purpose | Linked into app? |
|---|---|---|
| `EngineKit` | model-library extraction/prototype | No |
| `ProviderKit` | OpenAI/Anthropic clients and Keychain credential store | No |

## Build and test commands

Preferred local loop:

```bash
script/build_and_run.sh run
```

The script kills an existing GenStudio process, regenerates the project only when its tracked inputs changed, builds Debug into `.build/DerivedData`, and opens the app. `debug`, `logs`, `telemetry`, and `verify` select other modes. It always supplies `-clonedSourcePackagesDirPath .build/SourcePackages` so package resolution stays shared.

The app test command is:

```bash
xcodegen generate --spec project.yml
xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages test
```

Package tests are:

```bash
swift test --package-path EngineKit
swift test --package-path ProviderKit
```

On 18 September 2026, the app suite executed 392 tests: 377 passed, 15 opt-in real-model integration tests skipped, and 0 failed. The skip count is not compatibility evidence. EngineKit and ProviderKit are independent packages; rerun their suites whenever their code changes rather than treating old counts as permanent.

## App-owned native runtimes

`script/package_local_runtimes.sh` runs as an Xcode post-build phase. In Debug it removes stale embedded runtimes and XCTest payloads, then writes only a packaging stamp; Models → Start Here installs the checked, pinned `.vendor` runtime once under `~/Library/Application Support/GenStudio/RuntimeLibrary/Installed/native-2026-10-12`. In Release the phase copies only `bin`, `lib`, and `licenses` from `.vendor/llama` and `.vendor/sd`, plus the self-contained `.vendor/mlx-fastvideo` runtime, into `Contents/Resources/LocalRuntimes` and signs it. Model weights under `.vendor/sd/models` are development fixtures and are never copied into the app; MLX model weights are also never bundled.

`script/install_local_runtime.sh` provides the same one-time development bootstrap from the shell. Both paths stage the runtime before replacing the current app-owned installation.

`LocalRuntimeLibrary.engineRoot` resolves the signed bundled runtime when a Release bundle contains it and otherwise resolves the installed runtime. A missing or incomplete runtime is an actionable setup error; the app never substitutes a system Python, Homebrew installation, cloud service, or another local generation application.

## Build-cache lifecycle

`.build/DerivedData` and `.build/SourcePackages` are the only reusable development build caches. They can be removed to force a clean build, but doing so discards compiled output and shared package checkouts. Runtime installation and model weights live in Application Support, not `.build`, so a clean build does not require re-downloading or re-copying them. Keep temporary benchmark and validation output under `.build/` and remove it when no longer needed.

Pinned runtime evidence:

| Runtime | Pinned source | App use |
|---|---|---|
| llama.cpp | release b7100, commit c49daff5b (arm64 bundle) | text and vision child CLIs |
| stable-diffusion.cpp | release master-859-7f410a3, commit 7f410a3793c5bba8eb198e962ce7a3d6095f9d89 | image, video, and image/frame upscale paths |
| Managed MLX runtime | Python 3.13.5; MLX 0.32.2; mlx-vlm 0.7.1; Torch 2.12.0; Transformers 5.15.1; Diffusers 0.40.0; ltx-core-mlx/ltx-pipelines-mlx 0.16.3; mlx-lm 0.31.1; mlx-arsenal 0.2.4; exact lock | proven Qwen text/vision route plus typed FastMetal and LTX launchers |
| FastVideo source | commit c4824c776433555ab655a0dfc43c25f4dac20829 | exact FastMetal 5B T2V adapter, entered through `app/genstudio_fastmetal.py` so TAEHV/RIFE resolve from `share/genstudio-aux` (offline); launcher-measured on the M1 Max on 12 Oct 2026 |
| ltx-2-mlx source | v0.16.3, commit ae3b7ea9583db775bd4a1dfb506fb789585021e7 (wheels built from the tag, installed `--no-deps`) | exact LTX-2.3 Q4 distilled T2V/I2V adapter; the app sets `LTX2_COMPUTE_DTYPE=float16` |
| RifeMetal | Swift package 0.1.6 | Metal frame interpolation |

Release packaging first runs `script/verify_mlx_runtime.sh`, which checks the exact Python/package versions, imports the private launchers, and rejects symlinks that escape the runtime root. It removes development bytecode caches, disables runtime bytecode writes, then signs nested frameworks, dylibs and executables inside-out with the identity Xcode supplies. Debug installation copies only app-owned runtime content through an atomic staging directory and preserves the previous installation if setup fails. The app performs the same required-version check before MLX inference. There is no system Python, Homebrew, user-site, online repair, or silent alternate backend path.

## Model storage and lifecycle

Models are not shipped. At runtime the app constructs `ModelLibrary` at:

`~/Library/Application Support/GenStudio/ModelLibrary`

The library contains a registry, installed recipe directories, immutable `.recipe.json` manifests, staging directories, and resumable partial transfers. Each install automatically fetches every model and auxiliary component declared by the exact recipe, checks free disk space, expected component metadata, file structure, and SHA-256, preserves required nested layouts, and only then enters the registry. A model can be installed but unavailable if a component later disappears; resolution revalidates ownership and readability. Nested MLX packages are resolved from their common owned package root, so restart recognition and package removal work for both flat and nested recipes.

The app makes no Hugging Face credential request. Public discovery/download works; gated or private repositories fail with an explicit 401/403 remedy. Installed models continue to run offline.

## Network boundaries

- Hugging Face public API: discovery, metadata, revisions, and model downloads.
- No required network call exists for local inference after a model is installed.
- `ProviderKit` contains future OpenAI/Anthropic HTTP clients but is not linked into the app.
- Native child processes receive a scrubbed environment and do not inherit arbitrary proxy, Hugging Face token, or developer-shell variables.

## Credentials and data handling

The current app has no required credential. Future cloud integration must use `ProviderKit`'s Keychain abstraction, show provider identity per node, exclude secrets from workflow exports, and redact them from logs. Hugging Face tokens are intentionally not sent today.

Local projects, model files, intermediate media, and generated outputs are ordinary user files under Application Support. The app's current Sandbox-disabled posture means these files are accessible to the app without entitlement-mediated security-scoped bookmarks; this is convenient for local engines but must be considered before distribution.

## Signing and distribution

Debug is intended for local development. Release turns on Hardened Runtime. The repository supports an ad-hoc trusted-local package path and documents the Developer ID + notarization path, but there is no committed team ID, certificate, or notary credential. Public distribution is therefore not yet verified.

Run the detailed procedure in `PACKAGING.md`; do not invent signing identities or commit credentials. A release gate must verify outer and nested signatures, engine launch/version output, model-free bundle contents, licence inclusion, and Gatekeeper/notary acceptance.

## Observability and diagnostics

`script/build_and_run.sh logs` streams process logs, while `telemetry` filters the `studio.gen.GenStudio` subsystem. Run records and execution artifacts are the primary user-visible diagnostics. Native runner output is bounded and scrubbed before it is surfaced. Keep diagnostics actionable but free of API keys or raw credential headers.

## Operational risks

- Native engine ABI/CLI flags are pinned by evidence but still require re-proof when binaries change.
- Model downloads and generated media consume large local storage; preflight checks are part of the library/execution contract.
- Unified memory contention is managed by serialization, not by a remote scheduler.
- Sandbox-disabled access and unverified Developer ID signing are release risks.
- Several video recipes are descriptors awaiting decoded local proof; do not market them as verified merely because their command adapter exists.
- FastMetal is integrated and graph-routed. Launcher measurements on the reference M1 Max (12 Oct 2026, 5.04 s clips) were 832×480 in 88 s (46 s as a fast draft) and 1280×704 in 319 s (134 s); the in-app graph proof records itself on first run. These measurements are hardware-specific evidence, not a universal performance promise.
- `ModelLibrary/verified-components.json` records verified model-file fingerprints so unchanged files are not re-hashed each launch; deleting it only costs a re-hash. On launch, `StartupMaintenance` removes the pre-RuntimeLibrary `Runtime/mlx-vlm` venv and `GenerationScratch` entries older than 24 hours.
- macOS 26/27 with MLX can kill long GPU work while the display is on (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`). It hit one LTX decode on the 0.15.5 runtime; the 0.16.3 runtime's tiled decode has not hit it since. GenStudio does not set `AGX_RELAX_CDM_CTXSTORE_TIMEOUT`; unattended batches are safest with the display asleep.
- LTX-2.3 Q4 is integrated through the signed native-MLX runtime for T2V and I2V and is `awaitingProof` until real graph renders decode successfully. Its old CPU-offloaded stable-diffusion.cpp capabilities remain explicitly unavailable and may not be used as fallback.
- LTX-2.3 clips carry generated sound (48 kHz) when the installed package includes its two pinned sound files (`audio_vae.safetensors`, `vocoder.safetensors`, 365 MB). Packages installed before 12 Oct 2026 are video-only; Models → Add Sound Files extends them in place. Other video adapters are silent.
- The managed runtime has a fourth narrow launcher, `bin/genstudio-mlx-tts` (mlx-audio 0.5.4 text-to-speech, offline, no writes to HOME). Runtime completeness checks (`LocalRuntimeLibrary`, `install_local_runtime.sh`, `verify_mlx_runtime.sh`) require it, so an older install is replaced from `.vendor` on the next install.
- `brand-kit.json` and the `BrandKit/` folder (a copied logo) live in the GenStudio Application Support root. Stitcher music files are copied into the run's retained artifacts each time they render.
- Instagram Export keeps a 24, 25 or 30 fps source at its own rate (Reels, Facebook and WhatsApp accept all three) and asks for Frame Interpolation only for slower drafts.
