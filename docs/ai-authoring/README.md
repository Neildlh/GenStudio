# Teaching an AI to build GenStudio workflows

`GenStudio_AI_Briefing.md` in this folder is the complete knowledge pack. It is **generated from the app's own node contracts** (every node, port, wire type, setting, range and choice) plus hand-written design guidance and six worked examples. Do not edit it by hand.

## Using it (Hermes, or any chat AI)

1. In GenStudio choose **File → Copy AI Briefing** (or **Save AI Briefing…**). The same text is in this folder.
2. Put it at the start of the conversation, or in the agent's system prompt / persistent context / a loaded skill.
3. Describe the workflow you want.
4. Copy the AI's reply, then in GenStudio choose **File → Paste Flow from Clipboard** (or save the JSON and use **Import Flow…**). Fenced code blocks and surrounding prose are fine.
5. If the import fails, GenStudio puts a precise error report on your clipboard. Paste it back to the AI; it returns corrected JSON.
6. Attach the image/video files the AI listed under **You need to:**, and pick a model on generating nodes if none is set.

Imports always create a **new** workflow. Models, file paths and node positions are never part of a flow file: the app picks models the way a hand-added node does and lays the canvas out itself.

## Files

| File | Purpose |
|---|---|
| `GenStudio/FlowRecipe.swift` | Recipe file format, issue types, and the **settings catalog** (single source of truth) |
| `GenStudio/FlowRecipeCompiler.swift` | Recipe → workflow compiler (collects every error), exporter, tolerant JSON extraction |
| `GenStudio/FlowBriefing.swift` | Generates the briefing; holds the hand-written guidance and examples |
| `GenStudioTests/FlowRecipeTests.swift` | Compiler, exporter, parser, and briefing-drift tests |

## Keeping the briefing current

Adding or changing a node, port or setting changes the generated briefing, and `testCheckedInBriefingIsCurrent` fails until the file is regenerated:

```bash
TEST_RUNNER_GENSTUDIO_WRITE_BRIEFING=1 xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:GenStudioTests/FlowRecipeTests/testCheckedInBriefingIsCurrent
```

A new node kind needs an entry for each of its user-facing settings in `FlowSettingCatalog`; one test checks every default is valid and settable, another that every kind compiles alone. Hand-written guidance in `FlowBriefing.swift` must only state facts verified in code or `docs/`.
