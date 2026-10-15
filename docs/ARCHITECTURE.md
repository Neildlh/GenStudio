# GenStudio architecture

Status: implemented architecture audit
Last reviewed: 18 September 2026

## System shape

GenStudio is a single native macOS application. There is no GenStudio server, database service, worker service, or remote inference backend. Native MLX model families may run through an app-owned, isolated and version-pinned runtime; it is part of GenStudio's local execution path, never a user-managed developer environment or another application.

```text
SwiftUI/AppKit views
        │ user intent and bindings
        ▼
StudioModel (@MainActor)
  projects · library UI · runs · undo/redo · gallery
        │ validates and plans target graph
        ▼
ExecutionQueue (actor)
        │ dependency-ordered RuntimeValues
        ├── deterministic media processors
        ├── RifeMetal interpolation
        └── local engines
              ├── llama-cli / llama-mtmd-cli
              ├── sd-cli
              └── app-owned MLX launchers
                    │ child process + bounded pipes + flock
                    ▼
              decoded/validated media
        │
        ▼
StudioPersistence (actor)
  projects · runs · outputs · execution artifacts · retained media
```

The model-library path is parallel to execution:

```text
Hugging Face public API ──► ModelDiscovery
                                  │ recipe metadata
                                  ▼
                         ModelLibrary actor
                    staging → validate → register
                                  │ installed recipe
                                  ▼
                         native engine model paths
```

`LocalRuntimeLibrary` owns the runtime path independently of both the model library and the Debug app bundle. In Debug, Models → Start Here atomically copies the pinned `.vendor` runtime into `~/Library/Application Support/GenStudio/RuntimeLibrary/Installed/native-2026-10-12`. In Release, `LocalRuntimes` is signed inside the app bundle. Engine resolution uses the bundled resource when present and otherwise uses the installed app-owned runtime; it never probes system Python, Homebrew, or a user-site package.

## App composition

`GenStudio/AppAndViews.swift` composes the application and its three-column SwiftUI workspace. `StudioModel` is the main-actor composition root and owns the observable UI state, persistence actor, model library, execution queue, and native engine implementations.

The app target's source list is `GenStudio/` in `project.yml`. Its only Xcode package dependency is `RifeMetal` 0.1.6. SwiftUI/AppKit provide the desktop UI; Foundation, AVFoundation, Core Image, ImageIO, Core Graphics, Metal, CryptoKit, and FoundationModels support persistence, media, hashing, and native capabilities.

## Domain and graph contract

`GenStudio/Domain.swift` defines workflow identity, node kinds, named ports, typed values, run state, execution artifacts, takes, and schema compatibility. The six runtime value types are `text`, `textArray`, `number`, `image`, `video`, and `shotSequence`.

`GraphValidator.swift` checks unique node and edge IDs, valid port references, matching types, required inputs, duplicate input occupancy, cycles, file inputs, and (when requested) installed/runnable model inputs. `RunPlanning.swift` resolves a target's reachable graph into deterministic execution order and an input snapshot.

The graph deliberately distinguishes authored values from runtime values and successful takes. Output fan-out remains intact; repeatable image inputs retain order and identity. Workflow persistence currently supports schema version 3 and can read/migrate version 1 and 2 documents through the domain decoder.

## UI and state flow

`StudioModel` is `@MainActor` and owns the application-facing state. Views bind to the active project, selected node, inspector settings, model-library view model, queue progress, gallery, and history. User edits go through model methods so undo/redo, delayed saves, and stale-editor protection remain centralized.

The canvas supports pointer connection dragging in either direction, pan/zoom, selection, duplicate/cut/copy/paste (in place, and reconnecting inputs that still exist), graph-aware selection and align/distribute (`CanvasSelectionTools.swift`), deletion, auto-layout, and named port rendering. Inspector views are specialized by node/task and use the capability registries to show only controls supported by the exact selected recipe.

## Execution

Character Sheet emits its current category template through `characterSheetBrief`, incorporating optional author-supplied `characterSheetHeightCM` and `characterSheetPose` (Original/Standing/Seated, applied only to People/Character). Older documents decode height as nil and pose as Original. Decoded sheet nodes refresh their stored fixed brief without replacing separately retained locked finals. `WorkflowProject.characterSheetSource(feeding:)` follows text-preserving routers/previews. Image Generator passes such briefs through the prompt compiler's validated `preserveAuthoredText` route, avoiding both semantic LLM expansion and appended creative treatment while retaining prompt provenance. Explicit rewriting/composition nodes terminate this source lookup. Original image bytes continue through the normal reference-conditioning path.

`ExecutionQueue` is an actor. It validates and executes one dependency-ordered target graph at a time while allowing model-library transfers to continue separately. Heavy local inference is serialized because model components compete for Apple Silicon unified memory.

Deterministic nodes use Foundation/Core Image/ImageIO/AVFoundation paths. Native generation uses:

- `NativeGenerationEngine.swift`: local text generation through app-owned llama.cpp `llama-cli` or the exact `mlx-vlm` package route;
- `NativeVisionEngine.swift`: image description through `llama-mtmd-cli` or the same exact multitask `mlx-vlm` route;
- `NativeGenerationEngine.swift`/image paths: stable-diffusion.cpp `sd-cli` for image work;
- `NativeVideoEngine.swift`, `MLXFastVideoEngine.swift`, `MLXLTXVideoEngine.swift` and `VideoExecution.swift`: engine-routed stable-diffusion.cpp, FastVideo MLX, and native LTX MLX adapters, media staging and decoded-output validation;
- `NativeUpscaleEngine.swift` and `VideoUpscaleExecution.swift`: learned image/frame upscaling;
- `VideoFinishing.swift`: RifeMetal frame interpolation plus delivery finishing.

`NativeProcessRunner` launches child processes with a scrubbed environment containing only the values required for execution (including PATH, HOME, TMPDIR, and LANG), captures bounded output, and terminates on cancellation. A cross-process nonblocking `flock` prevents concurrent app-owned CLI jobs from competing unexpectedly.

Generated media is staged, decoded, checked for expected dimensions/timing/frames where the adapter requires it, and only then retained as a successful runtime value. Failed and cancelled attempts do not become successful gallery media.

## Capability and model architecture

Model recipes are declared in `ModelCatalog.swift`, `MediaModelCatalog.swift`, `MLXVLMModelCatalog.swift`, `MLXVideoModelCatalog.swift`, `VisionModelCatalog.swift`, and `UserModelCatalog.swift`. Task-specific contracts live in `ImageCapabilities.swift`, `VideoTasks.swift`, and `UpscaleCapabilities.swift`. A descriptor binds recipe ID, engine ID/build, task, component roles, dimensions/settings, readiness, and evidence.

The architecture treats three concepts separately:

- a **model recipe** is an immutable set of files, revisions, hashes and relative paths;
- a **backend** is the exact app-owned engine/build that knows how to load that recipe;
- a **capability** authorizes one exact recipe/backend pair for one task such as T2V or I2V, with settings, readiness and evidence.

Installation proves only that the recipe is present and intact. It does not grant
tasks. FastMetal has an `mlx-fastvideo` backend and a T2V capability but no I2V
capability; its capability also offers an opt-in fast draft (`VideoGenerationSettings.fastDraft`,
recorded on the request) that denoises every second frame and RIFE-interpolates the rest.
LTX-2.3 also has a start/end-frame capability: the start image conditions frame 0 and
the end image the last frame (`--image END last`, ltx-2-mlx ≥ 0.16). LTX capabilities declare
`producesAudio`: the request carries `sound` (on unless the clip's `VideoGenerationSettings.sound` is
false), the engine decodes the sound only when the installed package has its sound decoder, and the
decoded output must have an audio track exactly when sound was made.
Routes measured on the reference Mac carry `speedAnchors`; `VideoTimeEstimate` scales them to a
node's size and length for the inspector, batch confirmations and `RunPlan`.

Model files are SHA-256-verified before first use; verified fingerprints (path, size, file number,
modification time) persist in `ModelLibrary/verified-components.json`, so an unchanged file is not
re-hashed on the next launch. `ModelLibrary.extendInstalledPackage(id:to:)` adds pinned components to an
installed package in place when the new recipe is the installed one with files appended (LTX-2.3 gains its
365 MB sound decoder without re-downloading 30 GB): only the new files are fetched and verified, the
registry write commits, and a pending manifest covers an interruption between commit and manifest swap.
`StudioModel` memoizes per-node takes and latest results
(`CanvasLookupCache`) until `executionArtifacts` changes, and `StartupMaintenance` removes the legacy
`Runtime/mlx-vlm` environment and day-old scratch at background priority on launch.

`ModelAdvisor` (pure) judges installed models from this Mac's hardware, `canAttemptGeneration`, withdrawn capabilities, `MacFitStandard` verdicts (with their `advice` and `replacedBy`; statuses `meets`, `expectedToMeet`, `alternativeLook`, `finalQuality` and `doesNotMeet` — a `finalQuality` verdict must record its `wait`, the fast `draftWith` recipe and the `outranksDraft` evidence, and `FinalQualityBadge` shows it beside every model picker and on the node card; `RunPlan.finalQualityNodes` makes Run All name those nodes and ask first), workflow usage and run history; `ModelAdviceSection` presents it in the Models sidebar, and `StudioModel.switchNodes(from:to:)` moves nodes to a replacement with one undo step per workflow. `ModelAdvisor.recommendedRecipeIDs` is the single recommended set behind Start Here, `recommendedForThisMac` and the advisor. Every listing that offers a recipe (Start Here, Recommended, Advanced Search, What to try next, inspected repositories and the sidebar's Discover) uses one `ModelInstallControl`, whose state comes from the pure `ModelInstallState.resolve`: installed, downloading with progress and Cancel, queued with its place in line, blocked with `ModelLibraryViewModel.installBlocker`'s reason, or ready with the bytes still to download. `requestInstall` starts a download or, while one is running, appends it to `queuedRecipes`; each finished, failed or cancelled download starts the next. `ModelWatchlist.standaloneRoutes` lists unversioned routes (Z-Image Turbo) that the radar shows as "Also a strong fit" with an install action. `ModelRadarStore.checkIfDue()` runs a facts-only release check when the last one is over a week old. LTX-2.3 Q4 has a separate `mlx-ltx` backend with exact T2V and I2V
capabilities; its old stable-diffusion.cpp capabilities remain unavailable and
cannot be selected as fallback.

### Readiness: proof is a label, not a permission

`CapabilityReadiness` separates two questions that were previously conflated:

- **`executable`** — GenStudio has an adapter contract for this recipe/engine/task
  and the route has not been withdrawn. This is the execution gate.
- **`proven`** — a decoded local render has validated this exact tuple. This drives
  labelling, recommendation ranking and feed eligibility, and nothing else.

A recipe at `.awaitingProof` is therefore runnable: it executes on first use and
earns its proof from the decoded result. Requiring proof before the first run made
proof unobtainable without a developer change, which is why an installed, complete
FLUX.2 Klein 9B sat unusable beside a verified Klein 4B that shares its exact
command contract.

`.unavailable(reason:)` remains a hard block and its recorded reason is surfaced
to the user verbatim. These are known-broken routes, not merely unmeasured ones:
AnimateDiff's repeated identical frames and the withdrawn LTX-2.5
stable-diffusion.cpp path. Video adapters can still be withheld or rejected after
a process completes when decoded output fails temporal proof.

Decoded-output validation is unchanged and remains a hard gate on *results*. What
changed is permission to attempt, not the standard applied to what comes back.
`allowsUnverifiedLocalRun` survives as a persisted field so existing run snapshots
and workflow documents decode unchanged; it no longer grants permission.

Do not replace these registries with a generic “file extension means supported” rule.

`ModelDiscovery.swift` can inspect public Hugging Face metadata, but ordinary user-facing search is restricted to exact proof-gated GenStudio recipes. `ModelLibraryCore.swift`, `ResumableDownload.swift`, and `ModelLibraryUpdates.swift` implement staged/resumable downloads, locks, hash/structure checks, immutable manifests, nested relative-path preservation, registry persistence, managed imports, and update metadata. An update check treats an unchanged immutable repository revision as current even when Hugging Face omits LFS checksums for small Git metadata files; a changed revision still requires exact filename, size, and SHA-256 for every changed component before it becomes installable. Gated/private downloads fail clearly because no Hugging Face token is sent.

The app's actual model root is `StudioPersistence.root/ModelLibrary`, normally `~/Library/Application Support/GenStudio/ModelLibrary`. `Installed/` owns registered package roots; staging and partial-download state stay inside that library. Resolution derives one owned package root from all component paths, validates every path remains below `Installed/`, then reads that root's immutable manifest. This allows nested MLX layouts to survive restart and be removed as one package without weakening ownership checks.

## Persistence and lifecycle

`StudioPersistence` is an actor using sorted, pretty JSON with ISO-8601 dates and atomic writes. Its normal root is `~/Library/Application Support/GenStudio` with:

| Directory | Contents |
|---|---|
| `Projects/` | workflow JSON, plus `.deleted` tombstones |
| `Runs/` | queued/running/succeeded/failed/cancelled/interrupted records |
| `Outputs/` | text-output records |
| `ExecutionArtifacts/` | graph snapshots, runtime values, and provenance |
| `Artifacts/` | retained generated image/video files |
| `ModelLibrary/` | installed recipes, components, registry, and download state |
| `RuntimeLibrary/Installed/` | versioned app-owned local inference runtime for Debug builds |
| `GenerationScratch/` | temporary native-generation staging and scratch files |

**Flow files.** Besides the full-fidelity backup (`exportProject`, the raw workflow), a workflow can be exported and imported as a compact *flow recipe* (`.genflow.json`): human ids, node kinds, per-kind settings from `FlowSettingCatalog`, and `"a.out -> b.in"` wires. `FlowRecipeCompiler` builds nodes with `StudioModel.configuredNode` (so models match a hand-added node), applies `WorkflowAutoLayout`, and validates with `GraphValidator`, reporting every problem at once. Recipes carry no model ids, paths or coordinates. Import always creates a new workflow. `FlowBriefing` generates the AI briefing from the same catalog and node contracts; see [`ai-authoring/README.md`](ai-authoring/README.md).

**Project folders and locking.** A project can be bound to a folder (`WorkflowProject.homeFolder`). Each autosave also writes its `.genstudio` file there (`ProjectMirror`); the library copy stays as the fallback. A node can be locked as final (`StudioNode.finalized`): its chosen result is copied to `Links/images|video|prompts` named after the node heading, downstream nodes receive that file (`StudioModel.execute` pins it, `RunPlan.reachableNodes` stops at it), and heading renames rename the file (`reconcileFinalFiles` in `replace`, so undo/redo follow). Drafts, models and the runtime stay in the library. Package copies a project's references into a folder for handover. See [`PROJECT_PACKAGES.md`](PROJECT_PACKAGES.md).

On load, queued or running runs are recovered as interrupted. Project deletion writes a tombstone before removing the JSON record, preventing queued saves from resurrecting it. Gallery cleanup removes only unprotected retained files inside `Artifacts/`.

## Auxiliary packages and reference code

`EngineKit` is a separate Swift package containing a model-library extraction/prototype and tests. It is not a dependency in `project.yml` and is not compiled into the app target.

`ProviderKit` is a separate Swift package containing OpenAI Responses and Anthropic Messages clients, Keychain credential abstractions, and tests. It is not imported by `GenStudio/`; cloud nodes are future integration work.

HeliosGen is a separate upstream Next.js/Tauri project credited as inspiration. Its source is not included, built, packaged, or launched by GenStudio.

## Key decisions and risks

- App-owned CLIs and MLX runtimes avoid a user-managed Python/developer-tool dependency but require careful installation, nested signing for distribution, version pinning and per-engine compatibility evidence. Debug uses the one-time Application Support installation; Release resolves its signed bundled resource first.
- Actor isolation prevents races between UI, persistence, library downloads, and execution, but main-actor view state must not absorb blocking work.
- Explicit recipe/task readiness is more verbose than generic model discovery but prevents expensive, misleading runs.
- App Sandbox is disabled today to allow local runtime/model file access; this is a distribution and security decision that must be revisited before public release.
- Release Hardened Runtime is configured, but Developer ID/notarization has not been completed. See `PACKAGING.md`.
- Retained clips may carry one audio track. Only LTX-2.3 generates sound; the Stitcher keeps every clip's sound on one continuous track (silence where a clip has none), and Instagram Export, Video Upscale and Frame Interpolation keep it. Each LTX clip makes its own sound, so music generated per clip changes at every cut.
- Prompt Enhancer (`PromptEnhancer.swift`) resolves its destination by following its text output through routers, previews, Combine Text and Prompt Template to the first prompt or script socket, and builds the model instruction from a per-destination rule table (`PromptEnhancerTarget.rules`). Pictures the destination receives (start/end frames, references) are context sources: `ExecutionQueue` adds them to the enhancer's dependencies and passes them to `GraphValidator.validate` as `orderingDependencies`, run-order constraints that are never saved as wires; a source that depends on the enhancer is left out to keep the order acyclic. The enhancer is not a generic cached generative node: a downstream run reuses the latest successful enhancement whose `RunInputSnapshot.promptEnhancerFingerprint` (rough prompt, settings, destination, picture content hashes) matches, and running the enhancer itself always writes a new version.
- Video Prompt compiles one flowing, present-tense description (action, then a named `VideoCameraMove` direction, focus, motion, look, and finally sound and a quoted spoken line); `VideoShotRecipe` presets set how a shot is filmed, never what happens in it. End Card renders text, logo and colours with Core Text and AVAssetWriter, with no model; Text Overlay composites a Core Text caption over each frame with a Core Image video composition.
- The Stitcher (`assembleVideo`) keeps per-clip edits in `AssemblySettings.clipEdits`, keyed by clip-slot id so they follow a reordered slot: trims, a 0–1 sound level and an optional transition into the clip. `ClipAssembler.load` resolves each clip to the trimmed range that plays (optionally skipping the first frame of every clip after the first, for frame-chained shots) before either render path; `AssemblyTimeline` holds one transition and overlap per join, each overlap capped at 45% of the shorter neighbour. Fit or fill is a scale choice in `ClipAssembler.placement`; the render size crops the fill overflow. The settings in force, pruned to the current slots, are recorded in the run's `RenderedMediaProvenance.assembly`.
- Plain-cut stitches at full clip level keep the single-pass path. Dissolves, dips to black, fades, music or a reduced clip level use `ClipAssembler.assembleFinished`: a dip renders the outgoing clip fading to black over the first half of its overlap and the incoming one rising over the second, with its sound silent at the middle; clips alternate over two video tracks with opacity ramps, every sound (each clip's, crossfaded, and the looped music with a `VolumeEnvelope` that dips under clip sound and fades out) is mixed to one 48 kHz AAC track with `AVAssetReaderAudioMixOutput`, then muxed.
- `StudioModel` holds an idle-sleep assertion (`RunWakeGuard`) while runs execute or wait, and posts one notification (`RunBatchRecord`) when work over a minute finishes in the background. `MLXGPUWatchdog` retries an LTX or FastMetal process once when it fails with the macOS GPU-watchdog signature.
- Voiceover: `MLXSpeechEngine` (speech model kind, `mlx-audio` runtime family, `genstudio-mlx-tts` launcher, offline) speaks the script; `VoiceoverMixer` lays the decoded, non-silent voice over the incoming video and ducks its existing sound, mixing to one track. Image runs report engine time and log through the `EngineRunLog` task-local, and record thermal state, without changing the image engine protocol.

## Change map

| Concern | Start here |
|---|---|
| Node/port/value model | `Domain.swift`, `GraphValidator.swift`, `RunPlanning.swift` |
| Canvas interaction | `AppAndViews.swift`, `CanvasContextMenu.swift`, `WorkflowAutoLayout.swift`, `LayeredFlowLayout.swift` |
| Persistence/recovery | `Persistence.swift`, `Domain.swift`, `WorkflowLifecycleTests.swift` |
| Text/vision inference | `NativeGenerationEngine.swift`, `NativeVisionEngine.swift`, `MLXVLMRuntime.swift`, `ManagedMLXRuntime.swift` |
| Image inference | `ImageCapabilities.swift`, `NativeGenerationEngine.swift`, `ImagePromptSettings.swift` |
| Video inference | `VideoTasks.swift`, `NativeVideoEngine.swift`, `MLXFastVideoEngine.swift`, `MLXVideoModelCatalog.swift`, `VideoExecution.swift`, `VideoPreflight.swift` |
| Learned finishing | `NativeUpscaleEngine.swift`, `VideoUpscaleExecution.swift`, `VideoFinishing.swift` |
| Model discovery/install | `ModelDiscovery.swift`, `ModelLibraryCore.swift`, `ResumableDownload.swift` |
| Local runtime setup | `LocalRuntimeLibrary.swift`, `ModelLibraryViewModel.swift`, `script/install_local_runtime.sh`, `MLXRuntimeContractTests.swift` |
| Build/package/sign | `project.yml`, `script/build_and_run.sh`, `script/package_local_runtimes.sh`, `docs/PACKAGING.md` |
