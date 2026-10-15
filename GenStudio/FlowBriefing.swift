import Foundation

/// The knowledge pack that teaches an AI to author GenStudio flows. The node reference is generated from the
/// live node contracts and settings catalog, so it cannot drift from the app; a test keeps the checked-in copy honest.
enum FlowBriefing {
    static let fileName = "GenStudio_AI_Briefing.md"

    struct Example { let title: String; let note: String; let json: String }

    static func markdown() -> String {
        [header, formatSection, wiringSection, nodeReference(), guidance, examplesSection(), closing].joined(separator: "\n\n") + "\n"
    }

    // MARK: Generated reference

    static func nodeReference() -> String {
        var out = ["## Node reference", "", "Generated from the app. Every kind, port and setting listed here is real; nothing else exists. Kinds are grouped as they appear in the app's Add Node menu."]
        for category in NodeKind.categoryOrder {
            out.append("\n### \(category)")
            for kind in NodeKind.allCases where kind.category == category { out.append(entry(for: kind)) }
        }
        return out.joined(separator: "\n")
    }

    private static func entry(for kind: NodeKind) -> String {
        let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0))
        var lines = ["\n#### `\(kind.rawValue)` — \(kind.title)", kind.detail]
        if kind.usesModel { lines.append("*Runs a model. The importer picks an installed one; the user can change it afterwards. Never write a model name.*") }
        let dynamicKind = kind.supportsDynamicTextInputs || kind.supportsDynamicImageInputs || kind.supportsDynamicVideoInputs
        if kind == .shotSequence {
            lines.append("- **Inputs:** one `image` input per frame, addressed by the frame's `id` (see the `frames` setting). All optional.")
        } else if dynamicKind {
            let type = kind.supportsDynamicImageInputs ? "image" : kind.supportsDynamicVideoInputs ? "video" : "text"
            let defaults = node.dynamicInputs.map { "`\(FlowNaming.slug($0.label))` (\"\($0.label)\")" }.joined(separator: ", ")
            let sample = node.dynamicInputs.first?.label ?? "Item 1"
            lines.append("- **Inputs:** a list you declare with the node's `inputs` (labels); every socket is `\(type)`. Wire to a socket by its label or its slug (\"\(sample)\" → `\(FlowNaming.slug(sample))`). If you leave `inputs` out you get: \(defaults).")
        } else if node.inputPorts.isEmpty {
            lines.append("- **Inputs:** none.")
        } else {
            lines.append("- **Inputs:** " + node.inputPorts.map { "`\($0.id)` (\($0.type.rawValue), \($0.required ? "required" : "optional"))" }.joined(separator: " · "))
        }
        lines.append("- **Outputs:** " + (node.outputPorts.isEmpty ? "none." : node.outputPorts.map { "`\($0.id)` (\($0.type.rawValue))" }.joined(separator: " · ")))
        let settings = FlowSettingCatalog.settings(for: kind)
        if settings.isEmpty {
            lines.append("- **Settings:** none. Do not write `settings` for this kind.")
        } else {
            lines.append("- **Settings** (all optional):")
            for setting in settings {
                let base = display(setting.get(node))
                let defaultText = base.isEmpty ? "" : " · default \(base)"
                lines.append("  - `\(setting.key)` — \(setting.type.summary)\(defaultText). \(setting.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func display(_ value: FlowValue) -> String {
        switch value {
        case .string(let s): s.isEmpty ? "" : "\"\((s.count > 48 ? String(s.prefix(48)) + "…" : s).replacingOccurrences(of: "\n", with: "\\n"))\""
        case .number(let n): FlowNaming.plain(n)
        case .bool(let b): b ? "true" : "false"
        case .array(let items): items.isEmpty ? "" : "\(items.count) items"
        case .object(let o): o.isEmpty ? "" : "set"
        case .null: ""
        }
    }

    // MARK: Fixed text

    static let header = #"""
    # GenStudio Workflow Author — briefing

    You are helping a person design **workflows for GenStudio**, a local-first Mac app where AI image, video and text tools are nodes on a canvas connected by typed wires. The person gives you a concept. You reply with a **flow file** that GenStudio imports and lays out on the canvas. You never see the app, so this document is your complete knowledge of it. Follow it exactly.

    ## Your output contract

    Reply with, in this order:

    1. One or two sentences saying what the flow does.
    2. **One** fenced ```json code block containing the complete flow. No comments, no trailing commas, valid JSON only.
    3. A short list headed **You need to:** naming every node that needs a file from the user (image/video/mask inputs import empty) and any choice the user must make (for example "pick an installed image model on Hero Still").

    Hard rules:

    - Use only node kinds, ports and settings listed in the Node reference below. Never invent one. If the concept needs something GenStudio cannot do, say so in one sentence, use the closest real node, and add a `stickyNote` node explaining the gap.
    - Never write model names, model ids, file paths, node coordinates, UUIDs or colours. The app chooses models, the user attaches files, and the app lays the canvas out.
    - Keep the flow as small as the concept allows. Every node must earn its place.
    - If the concept is ambiguous, make a sensible choice, state it in the first sentence, and continue. Do not ask questions unless the concept is impossible to interpret.
    """#

    static let formatSection = #"""
    ## The flow file format

    ```json
    {
      "format": "genstudio.flow",
      "version": 1,
      "name": "Short descriptive name",
      "description": "One line about what this flow makes.",
      "nodes": [
        { "id": "brief", "kind": "prompt", "label": "Scene Brief", "settings": { "text": "A lighthouse at dusk" } },
        { "id": "still", "kind": "imageGenerator", "label": "Lighthouse Still", "settings": { "width": 1024, "height": 768 } },
        { "id": "view",  "kind": "imagePreview", "label": "Result" }
      ],
      "wires": [
        "brief.text -> still.prompt",
        "still.image -> view.image"
      ]
    }
    ```

    - `nodes[].id` — your own short name for the node (letters, digits, `-`, `_`). Unique in the file. Used only by `wires`.
    - `nodes[].kind` — one of the kinds in the Node reference, exactly as written (`imageGenerator`, not "Image Generator").
    - `nodes[].label` — optional human title shown on the card. Use specific labels ("Hero Still", not "Image Generator").
    - `nodes[].settings` — optional object; keys must come from that kind's Settings list. Omit anything you would leave at its default.
    - `nodes[].inputs` — only for nodes whose inputs you declare (Combine Text, Prompt Template, Image Describer, Assemble). A list of socket labels.
    - `wires[]` — strings of the form `"sourceId.outputPort -> targetId.inputPort"`. The source port may be left off when the source has exactly one output. Prefer writing both ports.
    """#

    static let wiringSection = #"""
    ## Wiring rules

    - There are six wire types: `text`, `textArray`, `number`, `image`, `video`, `shotSequence`. A wire only connects an output and an input of the **same type**. Masks are `image`.
    - An **input accepts exactly one wire.** An **output can feed any number of inputs** (fan-out is normal and encouraged).
    - The graph must not contain a cycle.
    - Required inputs must be wired or the node cannot run. Optional inputs may stay empty.
    - Prompt, Image Prompt, Video Prompt, Character Sheet, Prompt Template, Combine Text, Text Array, List Select, Number and Number to Text are evaluated automatically when a downstream node runs. Only generating and processing nodes are run by the user.
    - Wire to a node's `Preview` (text, image or video) at the end of every branch the user will want to look at.
    """#

    static let guidance = #"""
    ## How to design a good flow

    **Shape.** Most flows read left to right: inputs and prompts → generation → refinement → delivery/preview. Put what the user writes at the left and what they collect at the right.

    **Prompts.**
    - `prompt` is free text. `imagePrompt` and `videoPrompt` are structured builders that turn a few decisions (subject, lighting, camera…) into a well-formed prompt; prefer them when the concept is a described scene, and always set `subject` / `action`, or the node produces nothing.
    - `imagePrompt.aspectRatio` only describes the shape in the prompt. Also set the Image Generator's `width` and `height` to match.
    - `promptTemplate` fills `{{name}}` placeholders from wired text. Every placeholder must match one of the node's `inputs` labels exactly (case and spacing included), and every input needs a wire. Use it to reuse one prompt with several changing parts.
    - `promptEnhancer` turns a rough, human-written prompt into one written for where it is going. Wire `prompt.text -> enhancer.prompt` and `enhancer.text -> <image or video node>.prompt`. It reads the destination (image or video, its model, length and size) and looks at the picture that node receives, such as an `imageToVideo` start image, so its `image` input is only needed for a different picture. Use it whenever the person writes the prompt themselves in plain words; leave it out after `imagePrompt`, `videoPrompt` or `characterSheet`, which already write model-ready prompts.
    - `combineText` joins its wired inputs top to bottom with a separator. It needs at least one wire.
    - `textArray` splits text into items and `listSelect` picks **one** item by number. This does not run a batch; to make variants, fan one prompt out to several generators.

    **Images.**
    - `imageGenerator` can take up to three ordered reference images on `referenceImage`, `referenceImage2`, `referenceImage3`. More than one reference works with FLUX.2 Klein only. With Klein you can describe what each reference supplies using `referenceRoles`, for example `{"referenceImage": "the character's face and outfit", "referenceImage2": "the room to place her in"}`. Always describe roles when you use more than one reference.
    - Image sizes: FLUX.2 Klein accepts 512–1024 pixels in multiples of 16. Stay inside that unless the user asks otherwise, and enlarge afterwards with `imageUpscale` (2× or 4×) instead of asking for a huge canvas.
    - `imageUpscale` invents detail; it can alter faces and text. When exact pixels matter use `imageResize` instead.
    - `imageBlend` needs both images to be exactly the same size. `imageCrop` bounds are fractions from 0 to 1, and x + width and y + height must not exceed 1.
    - Masks: white marks the area to change, black is preserved. `maskOperations` adjusts a mask; wire the source image too so its size is checked.
    - `imageDescriber` looks at ordered images and writes a description. `characterSheet` writes a fixed production-sheet brief; connect its text to `imageGenerator.prompt` and connect the original image separately to the generator's Reference input.

    **Video.**
    - Video generation takes minutes per clip. Keep clips short (about five seconds) and leave `width` / `height` at the node's defaults: the chosen model applies its own tuned size. To enlarge a small draft, use `videoUpscale`.
    - Pick the node by what you have: `textToVideo` (prompt only), `imageToVideo` (a start image plus a motion prompt), `startEndVideo` (a start and an end image), `videoToVideo` (rework an existing clip), `guidedShot` (a `shotSequence` of timed frames).
    - `frameInterpolate` raises the frame rate smoothly. `instagramExport` keeps a 24, 25 or 30 fps source, so it is only needed before export for slower drafts.
    - `instagramExport` (Social Export) delivers the video with its sound at `format` vertical (9:16, the default), feed (4:5), square (1:1) or landscape (16:9), cropping the edges to fill.
    - For a video `videoPrompt`, `cameraMovement` names a camera move (for example `Gentle push in`, `Slow orbit`, `Crash zoom`, `Product turntable`), and `ambience`, `speaker` and `spokenLine` describe the sound LTX-2.3 generates with the clip. Keep a spoken line to about 12 words, and leave `music` empty when several clips are joined, because each clip makes its own music.
    - `textOverlay` puts a caption (`text`, optional `subtext`) over a clip at `position` top, middle or lowerThird, for the whole clip or from `startSeconds` for `durationSeconds`. Wire a clip's `video` in and its `video` on to `assembleVideo`.
    - `voiceover` speaks a `script` in a `voice` described in plain words over a finished video (wire `assembleVideo.video` in and its `video` on to `instagramExport`); music and clip sound dip under it. It needs the user's installed voice model, so list it under **You need to:**.
    - `endCard` is the closing card of an advert: set `headline`, `offer`, `contact` and `website`, optionally wire a logo `imageInput` into `logo` and a still into `background`, then wire its `video` into `assembleVideo` as the last clip.
    - `shotSequence` + `animatic` makes a deterministic timed slideshow with hard cuts and no AI motion. `assembleVideo` (the Stitcher) joins every connected clip end to end in slot order; set `transition` (cut, dissolve, dipToBlack), `framing` (fit or fill) and `skipRepeatedJoinFrame` for frame-chained Start/End shots.

    **Files and models.**
    - `imageInput`, `videoInput` and `maskInput` always import **empty**. Give each a specific label ("Character Reference", "Logo") so the user knows what to attach, and list them under **You need to:**.
    - Any node that runs a model needs one installed. Never pick or name one.

    **Common mistakes to avoid.**
    - Wiring `text` into an `image` input, or `image` into a `video` input. Check types.
    - Two wires into one input. Use a `combineText` or `promptTemplate` to merge text; use `imageCompare` to choose between two images.
    - Using `imageBlend` on different-size images, or a `listSelect` index past the end of the list.
    - Setting a key that is not in the kind's Settings list. Write nothing rather than guess.
    - Forgetting the `subject` (Image Prompt) or `action` (Video Prompt).
    - Declaring `inputs` for a kind that has fixed inputs.

    **Annotating.** Use a `stickyNote` (no ports, `text` setting) for a short instruction or a caveat. Do not use one per node.
    """#

    static let closing = #"""
    ## Before you answer, check

    1. Every `kind` is in the Node reference, spelled exactly.
    2. Every wire's ports exist on those kinds and both ends share a type.
    3. No input has two wires; no cycle.
    4. Every required input is wired.
    5. Every `settings` key is in that kind's list and every value is inside its range or choice list.
    6. There is a Preview at the end of each branch worth viewing.
    7. Media inputs are labelled and listed under **You need to:**.
    8. The reply is one sentence, one JSON block, and the **You need to:** list.

    If the user pastes back an error report from GenStudio, fix every problem listed and return the **complete** corrected JSON block again, not a patch.
    """#

    // MARK: Examples (each is compiled by the test suite)

    static func examplesSection() -> String {
        var out = ["## Worked examples", "", "Each example imports cleanly. Copy their style."]
        for (index, example) in examples.enumerated() {
            out.append("\n### Example \(index + 1) — \(example.title)\n\n\(example.note)\n\n```json\n\(example.json)\n```")
        }
        return out.joined(separator: "\n")
    }

    static let examples: [Example] = [
        .init(title: "Prompt to still to enlarged result", note: "A structured image prompt, one generator sized to match the aspect ratio, then a 2× enlargement and a preview.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Product Hero Still",
          "nodes": [
            { "id": "brief", "kind": "imagePrompt", "label": "Product Brief",
              "settings": { "subject": "a matte black wireless speaker on a walnut desk, morning light", "subjectCategory": "Product", "composition": "Hero product shot", "lighting": "Soft daylight", "visualLook": "Clean product photography", "aspectRatio": "4:5 portrait" } },
            { "id": "still", "kind": "imageGenerator", "label": "Hero Still", "settings": { "width": 832, "height": 1024 } },
            { "id": "big", "kind": "imageUpscale", "label": "Enlarge 2x", "settings": { "scale": 2 } },
            { "id": "view", "kind": "imagePreview", "label": "Final Image" }
          ],
          "wires": ["brief.text -> still.prompt", "still.image -> big.image", "big.image -> view.image"]
        }
        """#),
        .init(title: "Two references with named roles", note: "Klein takes up to three references. Each one is labelled with what it supplies. The user attaches both images.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Character in a Location",
          "nodes": [
            { "id": "face", "kind": "imageInput", "label": "Character Reference" },
            { "id": "room", "kind": "imageInput", "label": "Location Reference" },
            { "id": "action", "kind": "prompt", "label": "Scene Action", "settings": { "text": "She reads by the window as rain runs down the glass, warm lamp light, cinematic still" } },
            { "id": "still", "kind": "imageGenerator", "label": "Scene Still",
              "settings": { "width": 1024, "height": 576, "referenceRoles": { "referenceImage": "the character's face, hair and outfit", "referenceImage2": "the room and its lighting" } } },
            { "id": "view", "kind": "imagePreview", "label": "Result" }
          ],
          "wires": ["action.text -> still.prompt", "face.image -> still.referenceImage", "room.image -> still.referenceImage2", "still.image -> view.image"]
        }
        """#),
        .init(title: "Reusable prompt template", note: "Placeholders in the template match the declared input labels exactly; two prompts feed them.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Poster Variations",
          "nodes": [
            { "id": "product", "kind": "prompt", "label": "Product", "settings": { "text": "a ceramic coffee mug" } },
            { "id": "feel", "kind": "prompt", "label": "Feel", "settings": { "text": "calm, minimal, morning" } },
            { "id": "template", "kind": "promptTemplate", "label": "Poster Prompt", "inputs": ["product", "feel"],
              "settings": { "text": "A studio poster of {{product}}, {{feel}} mood, generous negative space" } },
            { "id": "poster", "kind": "imageGenerator", "label": "Poster" },
            { "id": "view", "kind": "imagePreview", "label": "Poster Preview" }
          ],
          "wires": ["product.text -> template.product", "feel.text -> template.feel", "template.text -> poster.prompt", "poster.image -> view.image"]
        }
        """#),
        .init(title: "Describe references, then generate", note: "An Image Describer with declared image sockets writes a brief that drives the generator. The scene image is also used as a reference, so one output feeds two inputs.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Reference Brief to Still",
          "nodes": [
            { "id": "hero", "kind": "imageInput", "label": "Character" },
            { "id": "place", "kind": "imageInput", "label": "Scene" },
            { "id": "look", "kind": "imageDescriber", "label": "Reference Brief", "inputs": ["Character", "Scene"] },
            { "id": "still", "kind": "imageGenerator", "label": "Hero Still" },
            { "id": "view", "kind": "imagePreview", "label": "Result" }
          ],
          "wires": ["hero.image -> look.character", "place.image -> look.scene", "look.text -> still.prompt", "place.image -> still.referenceImage", "still.image -> view.image"]
        }
        """#),
        .init(title: "Photo to a vertical reel", note: "Generate a small clip from a photo, enlarge it with Video Upscale, then export for Instagram.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Photo to Reel",
          "nodes": [
            { "id": "photo", "kind": "imageInput", "label": "Start Photo" },
            { "id": "motion", "kind": "videoPrompt", "label": "Camera Motion",
              "settings": { "mode": "imageToVideo", "action": "steam rises from the cup while the camera slowly pushes in", "cameraMovement": "Gentle push in" } },
            { "id": "clip", "kind": "imageToVideo", "label": "Small Clip" },
            { "id": "big", "kind": "videoUpscale", "label": "Enlarge Clip", "settings": { "scale": 4 } },
            { "id": "reel", "kind": "instagramExport", "label": "Reel Export" },
            { "id": "view", "kind": "videoPreview", "label": "Reel Preview" }
          ],
          "wires": ["photo.image -> clip.startImage", "motion.prompt -> clip.prompt", "clip.video -> big.video", "big.video -> reel.video", "reel.video -> view.video"]
        }
        """#),
        .init(title: "Stills to a timed animatic", note: "A Shot Sequence's frame ids are its inputs. The animatic renders them as a slideshow with hard cuts.", json: #"""
        {
          "format": "genstudio.flow", "version": 1,
          "name": "Three-Shot Animatic",
          "nodes": [
            { "id": "a", "kind": "imageInput", "label": "Opening Still" },
            { "id": "b", "kind": "imageInput", "label": "Middle Still" },
            { "id": "c", "kind": "imageInput", "label": "Closing Still" },
            { "id": "seq", "kind": "shotSequence", "label": "Shot Order",
              "settings": { "finalHoldSeconds": 2, "frames": [
                { "id": "open", "label": "Opening", "holdSeconds": 2, "boundary": "cut" },
                { "id": "middle", "label": "Middle", "holdSeconds": 3, "boundary": "cut" },
                { "id": "close", "label": "Closing", "holdSeconds": 2, "boundary": "cut" } ] } },
            { "id": "movie", "kind": "animatic", "label": "Animatic" },
            { "id": "view", "kind": "videoPreview", "label": "Animatic Preview" }
          ],
          "wires": ["a.image -> seq.open", "b.image -> seq.middle", "c.image -> seq.close", "seq.sequence -> movie.sequence", "movie.video -> view.video"]
        }
        """#)
    ]
}
