# GenStudio product requirements

Status: living description of the implemented product and its intended direction
Last reviewed: 18 September 2026

## Product summary

GenStudio is a local-first native macOS application for authoring and running visual AI workflows. A user connects prompt, model, media, editing, inspection, and export nodes on a typed canvas. The app discovers and installs compatible model recipes, invokes app-owned native engines, validates outputs, and persists the workflow, run record, retained media, and provenance locally.

The product exists to make capable local AI media workflows approachable without hiding their technical constraints. It combines a creator-oriented canvas with engineering-grade evidence about what an exact model/runtime combination can actually do.

## Target user

The primary user is a technically comfortable visual creator working on an Apple Silicon Mac who wants to:

- keep source media and generation on their own machine;
- try and compare open model recipes without assembling a separate Python/ComfyUI stack;
- express repeatable creative processes visually;
- refine generated media with deterministic tools;
- preserve successful outputs and understand how they were produced.

The current performance and compatibility baseline is an M1 Max MacBook Pro with 64 GB unified memory. Lower-memory or different Apple Silicon systems may need smaller recipes and are not assumed to match measured timings.

## Problem

Local generative tooling often makes one of two tradeoffs: it exposes a flexible but operationally complex graph/runtime stack, or it offers a simple interface that obscures model compatibility, execution, and provenance. Creative experiments also become difficult to reproduce when prompts, models, settings, intermediate media, and final exports are scattered.

GenStudio addresses this by combining:

- a reusable visual workflow as the durable creative document;
- exact model/task/runtime compatibility rather than generic file support claims;
- owned native execution with no dependency on another generation app;
- local persistence of projects, runs, media, and provenance;
- deterministic media operations alongside model inference.

## Product goals

1. Complete an end-to-end local text/image/video workflow from authoring through validated retained media and export.
2. Make model acquisition and compatibility understandable inside the app.
3. Preserve creative work across relaunches and failures.
4. Make unsupported or unproven behavior visible rather than silently substituting a different path.
5. Provide enough evidence and diagnostics for development and release decisions.

## Non-goals for the current release

- acting as a general runner for every Hugging Face repository;
- requiring Draw Things, ComfyUI, Ollama, a user-installed Python, or Homebrew at runtime; GenStudio may bundle and own an isolated, version-pinned MLX runtime where that is the only practical way to deliver a proven Apple-Silicon local path;
- a hosted collaboration service, account system, or remote project database;
- automatic cloud fallback when local execution fails;
- authenticated gated/private Hugging Face downloads;
- claiming production quality for every exposed experimental video adapter;
- retaining generated LTX audio in the current video artifact contract;
- native multi-anchor Guided Shot execution before a proven adapter exists;
- App Store distribution in the current sandbox-disabled form.

## Core journeys

### 1. Create and run a workflow

The user creates or opens a project, adds nodes, connects compatible named ports, selects installed models, edits settings, and runs a target node. GenStudio validates the reachable graph, creates a deterministic run plan, queues heavy work, and retains successful values and media. The user can cancel a run, inspect failures, choose among successful takes, and reopen the project later.

### 2. Discover and install a model

On a Debug build, the user opens Models → Start Here and chooses Set Up Working Core. GenStudio first atomically installs its pinned local runtime once, then searches or queues proof-gated compatible public Hugging Face packages. Model downloads include all declared auxiliary components, are resumable and staged, and preserve required nested layouts. GenStudio verifies expected size/hash and file structure before atomically registering a model. Interrupted or invalid downloads never become installed models, and installed packages are reconstructed and routed correctly after relaunch.

### 3. Generate and refine media

The user can build a prompt directly or with local text/vision assistance, generate an image or short video with a compatible recipe, compare takes, and pass the result through deterministic resize/crop/blend/colour/mask or video finishing nodes. Learned upscaling and RIFE interpolation are explicit operations with their own quality caveats.

### 4. Plan and deliver a sequence

The user orders stills in a Shot Sequence, creates an animatic, generates supported motion clips, stitches the clips into one video (trimmed, with a transition per join, fit or fill), and prepares a 9:16 H.264 Instagram Reel. Guided Shot remains an honest unavailable path until native multi-anchor generation is supported.

### 5. Recover work

If the app closes during execution, previously queued or running records reopen as interrupted with an actionable message. Completed artifacts remain available. Atomic writes and project-delete tombstones prevent partially saved or deleted projects from being resurrected by delayed saves.

## Functional requirements

### Workflow authoring

- Provide a native macOS three-column workspace with Projects, Models, Gallery, and History sections.
- Support canvas pan/zoom, selection, pointer-based connection dragging, reverse dragging, cut/copy/paste (including paste in place and paste-and-reconnect-inputs), duplication, deletion, graph-aware selection (invert, upstream, downstream, connected, same type), align/distribute, auto-layout, and undo/redo.
- When a Prompt directly feeds one Image Generator, typing `@reference` offers its connected Reference sockets. The saved mention resolves at run time to that image's compacted reference position, so an empty earlier socket cannot make the prompt identify the wrong image.
- Image Generator begins with three ordered Reference inputs and shows “Add another image input” only when its selected, available recipe declares a further reference slot. The canvas always shows the exact model limit rather than accepting images that would be ignored; a workflow requiring more references must use an adapter that explicitly supports them.
- Represent values with the types `text`, `textArray`, `number`, `image`, `video`, and `shotSequence`.
- Permit output fan-out, reject incompatible types, reject duplicate occupancy of a single input, and reject cycles.
- Preserve the order and identity of repeatable image inputs.
- Persist project name, nodes, edges, settings, viewport, and schema version.

### Node coverage

The implemented node catalog covers:

- prompts and values: authored prompts, structured image/video prompts, deterministic character/product sheet briefs, templates, text composition/arrays, selection, and numbers;
- local AI: text generation, image description, image generation, and supported video generation;
- media input: image, mask, and video files;
- deterministic image work: resize, crop, blend, compare, rotate/flip, blur, invert, colour correction, and mask operations;
- deterministic video work: frame extraction, shot sequences, animatics, clip assembly with sound, end cards, and Instagram export;
- learned finishing: image/video upscaling and Metal-accelerated frame interpolation;
- routing, previews, and notes.

The exact list and port contracts live in `GenStudio/Domain.swift`; documentation must not drift into a second node registry.

Character Sheet must provide category-specific layouts, age/species-appropriate poses, and optional author-supplied physical size without guessing measurements from images. Original references belong on Image Generator. Direct or text-preserving delivery of a Character Sheet brief must not invoke an LLM rewrite. See [the layout research](research/character-sheet-layouts-2026-10-14.md) for the design rationale and quality limits.

### Model library

- Discover public model metadata without claiming arbitrary compatibility.
- Pin recipes to repository revisions and expected component metadata.
- Check storage before and during installation.
- Resume safe partial transfers and prevent concurrent writers from corrupting the same download.
- Validate GGUF/SafeTensors structures where applicable, expected size, and SHA-256 before registration.
- Store an immutable installed recipe manifest and preserve corrupt/newer registries for diagnosis.
- Support managed imports of compatible files and selected dynamic public recipes.
- Surface update metadata without silently replacing an installed pinned model.
- Explain that gated/private repositories cannot be downloaded because Hugging Face credentials are not sent.
- Keep ordinary search limited to recipes with an exact app-owned backend, task contract and retained proof; expose unproven adapters only through an explicitly labelled evaluation path.
- Keep model identity, backend identity/build and task capability/readiness separate in storage, filtering and execution.
- Install the checked app-owned runtime before downloading the starter-model queue when it is absent. Keep the runtime outside Debug app bundles, replace it atomically, and preserve a complete previous installation if setup fails.
- Keep runtime engines and model weights distinct: the runtime is version-pinned app support, while model recipes are user-selected data under `ModelLibrary` and are never bundled.

### Execution

- Validate the target's reachable dependency graph and required inputs before execution.
- Execute in dependency order with typed runtime values.
- Serialize heavy in-process inference and use an interprocess lock for app-owned native CLI runtimes.
- Allow model download activity without blocking an unrelated generation run.
- Support cooperative task cancellation and terminate a running native child process, escalating if needed.
- Bound captured process output and expose actionable failures without secrets.
- Decode and validate generated media before treating the run as successful.
- Keep the latest attempt state separate from the last successful take.
- For managed MLX routes, require the app-owned pinned runtime and reject missing/wrong package versions rather than falling back to system Python, Homebrew, user packages, CPU offload, or another engine.

### Persistence and provenance

- Store projects, run records, text outputs, execution snapshots, and retained media under the user's GenStudio Application Support directory.
- Use atomic JSON writes and reject unsupported newer schemas without rewriting them.
- Record the graph/run input snapshot and resolved model/media provenance for successful generation.
- Preserve retained files that are still referenced by another gallery item or runtime value.
- Support explicit project, history, output, and artifact deletion.

### Errors and recovery

- Distinguish validation, unavailable engine, malformed data, persistence, timeout, cancellation, and empty-result failures.
- Provide a user remedy where a compatible model, input, proof, disk space, or network action is required.
- Never register partial model installs or leave cancelled generated media as a successful output.

## Capability policy

Capability is attached to an exact recipe, native engine build, and task. Current registries use readiness states such as verified, awaiting proof, and unavailable. The source registries and named evidence are authoritative; this document intentionally avoids duplicating a volatile model matrix.

A feature can be structurally implemented and covered by fixtures while its real-model path is still awaiting proof. Promoting such a path requires a successful local run, decoded output validation, recorded provenance, and the evidence referenced by the registry. Build success alone is insufficient.

## Cloud direction

The intended cloud feature is an explicit node with a visible provider, using a user-supplied OpenAI or Anthropic key stored in Keychain. Keys must never appear in workflow exports or logs, and a local failure must never cause an automatic cloud request.

`ProviderKit` currently implements and tests provider clients and credential storage as a separate Swift package. Integration into `project.yml`, the app composition root, canvas contracts, persistence, UI, and end-to-end tests remains future work.

## Non-functional requirements

### Privacy and security

- Local inputs and outputs remain local unless the user explicitly invokes a future cloud node.
- Native child processes receive a scrubbed environment rather than the developer shell environment.
- API credentials belong in Keychain and must be redacted from diagnostics.
- Downloaded components must pass pinned validation before registration or use.

### Reliability

- File writes that define user-visible state are atomic.
- Cancellation and relaunch do not manufacture successful artifacts.
- Malformed and newer user data is preserved for recovery.
- Long-running work does not block SwiftUI's main actor.

### Performance

- Heavy local inference is serialized to avoid competing for unified memory.
- Model recipes expose conservative settings and measured baselines where real evidence exists.
- UI state updates remain main-actor isolated; file, network, and process work occurs off the UI path.

### Accessibility and usability

- Node contracts, validation failures, and unavailable capabilities use meaningful names and remedies.
- A user should be able to understand which model and task will run before starting expensive inference.
- Deterministic operations should remain available without a model when they can satisfy the task exactly.

## Success conditions

The product is succeeding when a user can:

1. install or import a compatible model with its provenance intact;
2. build a valid typed workflow without hidden connections or substitutions;
3. run it locally, cancel it safely, and receive a decoded retained result or actionable failure;
4. reopen the project and recover its graph, run history, takes, and media;
5. finish and export useful media while understanding which operations were generative and which were deterministic.

Release readiness additionally requires clean automated tests, direct smoke tests of bundled engines, model-specific media proofs for advertised capabilities, licence review, and successful signing/notarization for the chosen distribution channel.

## Open product decisions

- Which cloud node set should be integrated first, and which workflow data may each provider receive?
- What minimum Apple Silicon and memory tiers will be formally supported beyond the current M1 Max/64 GB evidence baseline?
- Should authenticated Hugging Face access be added, and how will gated model licences be presented and audited?
- Which native runtime can satisfy Guided Shot's multi-anchor contract without weakening it into pairwise transitions?
- What sandbox/distribution strategy can preserve local engine execution and user-selected model access?
