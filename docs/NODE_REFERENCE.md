# GenStudio node reference

This is the quick reference for the 49 node kinds in the current canvas. It explains a node's purpose, not every port or setting. For the exact importable node contract—kind names, ports, wire types, settings, ranges, and examples—use the generated [AI workflow briefing](ai-authoring/GenStudio_AI_Briefing.md). For current model/backend/readiness status, use [node/model coverage](NODE_MODEL_COVERAGE.md).

## How nodes fit together

Nodes pass six named, typed values: text, text arrays, numbers, images, video, and shot sequences. An input accepts one compatible wire; one output may feed many inputs. A workflow must be acyclic. Prompt and composition nodes calculate automatically when a downstream processing or generation node runs.

### Inputs and prompts

| Node | What it does |
|---|---|
| Prompt | Supplies authored text to another node. |
| Image Prompt | Builds an image prompt from creative choices such as subject, framing, lighting, and look. |
| Video Prompt | Builds a source-aware video prompt with action, camera direction, motion, look, and optional sound guidance. |
| Prompt Enhancer | Uses a local text model to rewrite a rough prompt for the destination image, video, or voiceover node and can use its input image as context. |
| Prompt Template | Fills `{{placeholder}}` variables in a prompt from named text inputs. |
| Combine Text | Joins ordered text inputs with a chosen separator. |
| Text Array | Splits text into an ordered list of up to 256 items. |
| List Select | Selects one text-array item by its one-based position. |
| Number | Supplies a numeric value. |
| Number to Text | Converts a connected numeric value to text. |
| Character Sheet | Creates a fixed production turnaround brief for a person, character, animal, or product; original images still connect directly to Image Generator references. |
| Local Text | Generates text through the selected local text model. |

### Media inputs and image work

| Node | What it does |
|---|---|
| Image Input | Imports image pixels from the Mac. |
| Video Input | Imports a video from the Mac. |
| Mask Input | Imports a mask; white marks the area to change and black preserves it. |
| Image Generator | Generates an image from text, optionally with ordered reference images when the selected recipe supports them. |
| Image Describer | Uses a local vision model to describe one or more ordered images. |
| Image Upscale | Uses a local learned model to enlarge an image 2× or 4×; it can alter fine detail. |
| Image Resize | Changes image dimensions deterministically. |
| Image Crop | Crops an image by normalized bounds. |
| Image Blend | Composites a foreground over a same-size background at chosen opacity. |
| Image Compare | Shows two images and sends the chosen one downstream. |
| Image Rotate / Flip | Flips an image and rotates it in 90-degree clockwise increments. |
| Image Blur | Applies local Gaussian blur. |
| Image Invert | Inverts RGB while preserving alpha. |
| Colour Correct | Matches a generated image's overall colour and tone to a source image while preserving its detail. |
| Mask Operations | Inverts, grows/shrinks, and feathers a mask with deterministic Core Image operations. |

### Video generation and finishing

| Node | What it does |
|---|---|
| Text to Video | Generates a short local video clip from a prompt using a task-compatible installed recipe. |
| Image to Video | Animates a start image from a motion prompt. |
| Start/End Video | Generates a transition between first and last images with a dedicated compatible recipe. |
| Guided Shot | Describes a multi-anchor shot from a timed Shot Sequence; it remains unavailable until native multi-anchor execution is proven. |
| Video to Video | Re-generates an existing clip from its frames and an edit prompt when a compatible recipe is available. |
| Extract Frame | Extracts an image from a video at a time in seconds. |
| Frame Interpolation | Uses Metal-accelerated RIFE to create smoother delivery frames without diffusing every frame. |
| Video Upscale | Learns a 2× or 4× spatial enlargement of each video frame, then re-encodes the original timing and audio. |
| Social Export | Delivers a sound-preserving H.264 video in 9:16, 4:5, 1:1, or 16:9 at 1080 px. |
| Shot Sequence | Orders still frames with stable slots, hold times, transition notes, and cut/continuous boundaries. |
| Animatic | Renders a Shot Sequence as a deterministic timed slideshow with hard cuts and no AI motion. |
| Stitcher | Joins connected clips in slot order, with trims, cuts/dissolves/dips, fit/fill, clip sound levels, fades, and an optional ducked music bed. |
| Voiceover | Uses a local speech model to put a described voice and script over a video while ducking existing sound. |
| Text Overlay | Renders a timed caption over a video while retaining its sound. |
| End Card | Locally renders a branded closing card as both a short video clip and a still image; it does not call a model. |

### Flow, inspection, and notes

| Node | What it does |
|---|---|
| Text Router | Fans one text input out through two independently connectable outputs. |
| Image Router | Fans one image input out through two independently connectable outputs. |
| Video Router | Fans one video input out through two independently connectable outputs. |
| Text Preview | Inspects a connected text value. |
| Image Preview | Inspects a connected image value. |
| Video Preview | Inspects a connected video value. |
| Sticky Note | Adds a non-executing annotation to the workflow. |

## Compatibility and proof

Generation nodes only offer exact recipe/backend/task combinations declared in the capability registries. Installation proves a package is present, not that every task works. A capability marked `awaitingProof` may run and earns proof only when its result is decoded, validated, and retained; a capability marked `unavailable` cannot run. See [Product](PRODUCT.md) and [Architecture](ARCHITECTURE.md) for the invariant and [node/model coverage](NODE_MODEL_COVERAGE.md) for the current routes.

## Maintaining this reference

`GenStudio/Domain.swift` is the source for node kinds, human titles, descriptions, categories, and default ports. Update this quick map when a node's user-facing purpose changes. For any port or setting change, update the app's `FlowSettingCatalog` and regenerate `ai-authoring/GenStudio_AI_Briefing.md` using the command in [the AI-authoring guide](ai-authoring/README.md).
