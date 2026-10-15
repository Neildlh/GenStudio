# GenStudio contributor guide

Before changing product behaviour or architecture, read:

1. `docs/AI_DEVELOPMENT_REFERENCE.md`
2. `docs/PRODUCT.md`
3. `docs/PRD.md`
4. `docs/ARCHITECTURE.md`
5. `docs/INFRASTRUCTURE.md`

Use `docs/INDEX.md` for public documentation routes.

## Authority order

When sources disagree, use this order:

1. current source, `project.yml`, scripts, and tests;
2. `docs/PRODUCT.md` for product invariants;
3. canonical documents in `docs/INDEX.md`;
4. historical material only when current code confirms it.

The Xcode app target compiles `GenStudio/` and depends only on RifeMetal. `EngineKit` and `ProviderKit` are separate packages, not app-target dependencies.

## Product invariants

- GenStudio is local-first; never add a silent cloud fallback.
- Compatibility is exact to model recipe, engine build, and task. Installation is not proof of inference support; only `.unavailable` blocks an execution attempt.
- Preserve typed named ports, ordered repeatable inputs, output fan-out, acyclic graphs, and persisted workflow compatibility.
- Preserve provenance, cancellation, actionable errors, interrupted-run recovery, atomic persistence, and decoded-media validation.
- Do not bundle model weights or log/export API keys.

## Build and verification

Regenerate Xcode after editing `project.yml`:

```bash
xcodegen generate --spec project.yml
```

Run app tests:

```bash
xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages test
```

Run package tests when their packages change:

```bash
swift test --package-path EngineKit
swift test --package-path ProviderKit
```

The public source tree intentionally omits the large app runtime and all model weights. Do not claim a fresh clone supports generation until the runtime bootstrap documented in `docs/OPEN_SOURCE_RELEASE.md` exists and has been verified.
