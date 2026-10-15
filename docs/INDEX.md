# GenStudio documentation index

This public-source edition keeps the current product and engineering contracts. Historical experiment logs, local-path evidence, agent configuration, and the uncompiled reference checkout are intentionally excluded. Small, sanitized proof fixtures required by the source tests remain under `docs/evidence/` and `docs/research/model-expansion/`.

| Document | Use it for |
|---|---|
| [`../README.md`](../README.md) | Project overview, source-build status, licence, attribution, and repository map |
| [`PRODUCT.md`](PRODUCT.md) | Product purpose and non-negotiable user-facing invariants |
| [`PRD.md`](PRD.md) | Target users, journeys, requirements, and release scope |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Implemented components, data flow, persistence, and decisions |
| [`INFRASTRUCTURE.md`](INFRASTRUCTURE.md) | Build system, runtime model, storage, network boundaries, and distribution posture |
| [`AI_DEVELOPMENT_REFERENCE.md`](AI_DEVELOPMENT_REFERENCE.md) | Compact routing guide for a coding agent |
| [`NODE_REFERENCE.md`](NODE_REFERENCE.md) | Purpose of all 49 current node kinds |
| [`ai-authoring/README.md`](ai-authoring/README.md) | AI-authored workflow import/export and the generated exact node contract |
| [`PROJECT_PACKAGES.md`](PROJECT_PACKAGES.md) | Project folders, locked final outputs, and handover packages |
| [`OPEN_SOURCE_RELEASE.md`](OPEN_SOURCE_RELEASE.md) | Public release, runtime delivery, privacy, and signing checklist |
| [`PACKAGING.md`](PACKAGING.md) | Local packaging and the separate future notarized-distribution path |

## Source of truth

Current source, `project.yml`, scripts, and tests outrank prose when implementation details conflict. `PRODUCT.md` is the product-intent authority. Capability support is time-sensitive: inspect the exact registries in `GenStudio/ImageCapabilities.swift`, `GenStudio/VideoTasks.swift`, and `GenStudio/UpscaleCapabilities.swift` before claiming a model/task combination works.

An installed model or a successful process exit is not proof of a compatible task. A model result must be decoded and validated before it is called proven.
