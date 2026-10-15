# Contributing to GenStudio

Thank you for wanting to improve GenStudio. This is a source-first technical preview, not yet a finished runtime distribution; check the [open-source release guide](docs/OPEN_SOURCE_RELEASE.md) before assuming that local generation setup is available.

## Before opening an issue or pull request

- Use an issue for reproducible bugs and scoped proposals. Use Discussions, when enabled, for questions and open-ended ideas.
- Explain the user-facing problem first. Include macOS/Xcode version, Apple Silicon hardware, model recipe and task only when they matter.
- Never include API keys, Hugging Face tokens, private media, private paths, Apple signing material, or model weights.

## Pull requests

- Keep one user-visible change per pull request.
- Preserve local-first execution, typed named ports, graph acyclicity, output fan-out, atomic persistence, cancellation, validated media, provenance, and explicit recipe/backend/task compatibility.
- Do not add a silent cloud fallback or treat installation/process exit as model proof.
- Add or update focused tests and relevant canonical documentation.
- Run the app test suite before requesting review.

The project guidance in `AGENTS.md` and the documentation index are the technical starting points.
