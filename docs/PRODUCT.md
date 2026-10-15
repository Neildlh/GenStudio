# GenStudio product contract

## Purpose

GenStudio is a local-first native macOS visual AI studio. Its purpose is to let a creator discover and manage compatible models, combine prompts and source media on a reusable node canvas, execute the work on their own Apple Silicon Mac, and keep validated outputs with enough provenance to understand and reproduce how they were made.

It is inspired by the flexibility of a Weavy-style creative canvas, but it owns the complete local execution path. It is not a wrapper around Draw Things, ComfyUI, Ollama, or another installed generation application.

## Intent

The product is intended to make local generative work understandable and durable:

- visual workflows make creative intent, model choice, and media flow explicit;
- local execution gives the user control of source media, models, outputs, and cost;
- exact capability contracts prevent the interface from promising unsupported combinations;
- retained runs, takes, artifacts, and provenance turn experiments into work that can be reopened and refined;
- deterministic editing and finishing nodes complement AI generation rather than forcing every operation through a model.

The reference development machine is an M1 Max MacBook Pro with 64 GB unified memory. That target guides conservative model recipes and measured baselines; it does not make performance universal across all Macs.

## Product principles

1. **Local by default.** After compatible models are installed, the core generation workflow works without a hosted inference service.
2. **Explicit compatibility.** Support belongs to an exact model recipe, task, and native engine build. GenStudio never claims that every Hugging Face file can run.
3. **Proof over appearance.** Acceptance depends on decoded, validated, retained media and independently exercised workflows—not screenshots, placeholder nodes, process exit alone, or a successful build.
4. **Recoverable work.** Cancellation, actionable failures, atomic persistence, interrupted-run recovery, and retained successful takes are part of the product contract.
5. **Visible data flow.** Named typed ports carry text, arrays, numbers, images, video, or shot sequences. Connections can be dragged in either direction, output fan-out is preserved, and ordered repeatable inputs retain their distinct values.
6. **No hidden substitution.** Unsupported tasks fail with an explanation and remedy. GenStudio does not silently change the requested model, task, or local/cloud execution path.

## Core outcome

**Character Sheet** supplies a fixed reference-board brief. People and Character use a portrait board with four body rotations, three face studies, and three defining-detail crops; Animal and Product use six larger landscape studies. People retain age-appropriate standing or seated poses. Original pictures of one subject connect directly to Image Generator Reference inputs. Optional known height in centimetres (infant length or quadruped shoulder height where applicable) adds a size caption; unknown sizes are never inferred. Body views share aligned pose bounds, without a generated ruler or a claim of calibrated measurements. Suggested canvases are 816 × 1024 for People/Character and 1024 × 768 for Animal/Product. Prompt guidance cannot guarantee identity, accurate lettering, or unseen geometry.

People/Character sheets also expose Body pose: Original, Standing, or Seated. Original asks the image model to preserve the source; explicit Standing/Seated removes that inference and is recommended when pose matters (for example Seated for a seated infant). The selected pose is persisted and exported, and only that pose instruction reaches the image generator.

The complete product journey is:

> Prompt and source media → optional local text/vision refinement → image or video generation → deterministic finishing → validated retained media → reopen, compare, assemble, and export.

The main library sidebar exposes four creator-facing views: Workspaces for workflow documents, Models for installed recipes and storage, Images for retained generated image/video media and text content, and Errors for failed or interrupted generations with direct node navigation and retry actions. Retained media can be named and exported in batches to a user-selected folder. A project can live in a folder you choose, like an InDesign job: its workflow file and a `Links` folder (images, video, prompts). Locking a node saves its chosen result there under the node's heading and makes that file the node's final value downstream. Finished projects can be packaged for handover, removed from the app, and opened again later from the folder.

Users search a proof-gated catalogue of exact GenStudio recipes, install complete pinned packages, import supported local files for recovery/evaluation, and choose only task-compatible models per generative node. Downloads may require a network connection; compatible installed recipes continue to execute locally. The app owns one isolated, version-pinned runtime for llama.cpp, stable-diffusion.cpp, the proven Qwen text/vision route, and the integrated FastMetal and LTX video routes. Debug installs that runtime once under `~/Library/Application Support/GenStudio/RuntimeLibrary/Installed/native-2026-10-12`, so it is not recopied or re-signed into every clean app build; Release packages the signed fallback. Users never install Python, uv, Homebrew, or a separate generation application.

Start Here has a compact one-click setup that installs the pinned local runtime when needed, then queues the models that met the speed-and-quality bar on the reference Mac: Qwen3.8-27B MLX 4-bit, FLUX.2 Klein 9B, FastMetal 5B (fast text-to-video drafts), LTX-2.3 MLX Q4 (final text-to-video and image-to-video) and Real-ESRGAN x4plus. Generation nodes can queue a batch of fresh-seed takes in one step, for unattended (for example overnight) runs. LTX-2.3 also makes start/end-frame clips in about 3 minutes; MiniMax-H3 FL2VA remains the slower, higher-quality start/end route.

Models come in two tiers. **Fast** models meet the speed-and-quality bar and are for drafts and checks. **Final quality** models miss the speed bar but have recorded evidence that they beat the fast model for the same job (today: MiniMax-H3, about 25 minutes a clip, drafted with LTX-2.3). Every node picker, the inspector and the node card mark a final-quality model with an amber clock and its wait, so a long render is always chosen knowingly; Run All names those nodes before it starts. A slow model without better quality stays below the bar. Juggernaut XL v9 is kept as an alternative photographic look rather than flagged for removal. Switching a node between models keeps its prompt, negative prompt, seed, clip length and shape. Choosing a model adopts its tuned settings while keeping the clip's length, shape and seed, and measured routes show a per-take time estimate.

**Start Video Ad** (empty canvas, or New Video Ad in the sidebar) builds a real local 9:16 advert with sound: three shots, each a FLUX.2 Klein 9B still animated by the chosen video model (LTX-2.3 by default, about 6½ minutes per 5 s vertical clip on the reference Mac; MiniMax-H3 for maximum quality at 25+ minutes, silent), each directed by a Video Prompt with a different camera move and the setting's sound, then an End Card (logo, offer, WhatsApp number) over the last still, joined in order and exported at 1080×1920, 24 fps. A whole ad takes roughly half an hour.

**Prompt Enhancer** (in the quick-add list, right after Prompt) sits between a plain-words Prompt and an image or video node and rewrites the prompt for where it is going. The local Qwen model reads the destination (image, animate an image, start/end, text to video, voiceover; its length and size) and looks at the picture that node receives, such as the start image of an Image to Video, then writes a prompt in that model's style: motion paced to the clip, identity kept to the picture, a stated camera, typos corrected. About 25 seconds per prompt on the reference Mac. Generating again reuses it until the rough prompt, destination or model changes.

**Video Prompt** writes one flowing shot description models read well: the action, a named camera move (23 Higgsfield-style moves from a locked tripod to crash zoom, FPV fly-through and product turntable, each with its exact direction), focus, motion, look and sound. Shot recipes (Product hero, Service in action, Happy customer, Location opener, Social hook, Detail close-up, Walk-in welcome, Big reveal) set the filming in one click. **End Card** renders the closing card locally in seconds.

**Finishing an advert.** A **Brand Kit** (business name, offer, contact, colours, logo; `brand-kit.json` in Application Support) fills every new End Card, Text Overlay and Start Video Ad. **Text Overlay** puts a caption over a clip for all or part of it. **Stitcher** (stored as `assembleVideo`, formerly Assemble) joins every connected clip into one video in slot order: per-clip trims (AI clips often settle over their first frames), a cut, cross-dissolve or dip to black chosen per join, fit or fill for mixed shapes, a sound level per clip, an option to skip the repeated frame at frame-chained joins, fades from and to black, and one music track under the whole video that dips under each clip's own sound and fades out. Its inspector shows each clip's first played frame and the stitch's running time before it runs. **Social Export** delivers 9:16, 4:5, 1:1 or 16:9 with sound. While anything runs or waits, the Mac is kept from idling to sleep, and long work that finishes in the background posts a notification. An MLX video job stopped by the macOS GPU watchdog is retried once automatically.

**Voiceover** speaks a script over a finished video with a local voice model (Qwen3-TTS Voice Design, part of Start Here). The voice is described in plain words, for example a warm South African woman; amounts like R150 are read as "150 rand"; clip sound and music dip under the voice. Image runs record their engine time, log and the Mac's thermal state.

The Models sidebar judges every installed model for this Mac: **Keep**, **Can't be used on this Mac** (missing files, too little memory, or no working route) or **Not needed** (below the speed-and-quality bar, a duplicate, or replaced by a better route; final-quality and alternative-look models are kept), each with a plain reason, the workflow nodes that use it, this Mac's own run times and the space it frees. It flags workflow nodes that point at models that are not installed, moves nodes to the recommended replacement in one undoable step, and offers removal only as a confirmed action. Model Library's recommended list shows only models that fit this Mac and meet its bar, node pickers label below-the-bar models, and the release radar re-checks Hugging Face on its own once a week. Evaluation cards do not become normal proof-gated recommendations until their exact graph task has useful decoded-media evidence on the reference machine.

## Cloud intent and current boundary

Optional OpenAI and Anthropic nodes are part of the product direction, with explicit provider identity, user-supplied credentials stored in Keychain, and no automatic cloud fallback. The repository contains a separately tested `ProviderKit` implementation, but the current macOS target does not link it and the canvas does not yet expose cloud nodes. Cloud execution is therefore planned infrastructure, not a shipped app capability.

## Deliberate boundaries

- Model weights are not bundled with the app.
- Public Hugging Face discovery is supported; gated/private downloads are not yet authenticated.
- A recipe may be visible or installable while a particular task remains experimental, awaiting proof, or unavailable. A task awaiting proof is runnable and records its own proof from the first decoded result; only an explicitly unavailable task is refused, with its recorded reason shown.
- Multi-anchor Guided Shot authoring exists, but execution remains unavailable until a native multi-keyframe adapter is integrated and proven.
- HeliosGen is credited as inspiration but is not included in this repository; `EngineKit` and `ProviderKit` are not part of the app target.

See `PRD.md` for requirements and scope, `ARCHITECTURE.md` for implementation, and `AI_DEVELOPMENT_REFERENCE.md` for a portable development context.
