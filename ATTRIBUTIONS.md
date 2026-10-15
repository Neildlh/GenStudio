# Attributions and third-party notices

GenStudio began as a personal project inspired by [HeliosGen](https://github.com/SegFault42/HeliosGen) by SegFault42. HeliosGen's visual AI-workflow concept sparked the initial experiment. GenStudio subsequently evolved into a separate native macOS application focused on app-owned local runtimes, local models, richer typed-node interaction, project files and handover, capability proof, retained media, and deterministic finishing.

The HeliosGen source repository is **not included** in this public repository, compiled into the GenStudio macOS target, bundled with the app, or required to run GenStudio. Any future inclusion of copied or adapted upstream material must retain every applicable copyright and licence notice.

## Runtime and model material

The development environment includes app-owned runtime material under `.vendor/`. It is deliberately ignored by Git and must not be treated as automatically distributable source:

- `llama.cpp` runtime material includes upstream notices under `.vendor/llama/licenses/`.
- `stable-diffusion.cpp` runtime material records its upstream revision and MIT notice in `.vendor/sd/MANIFEST.md`.
- The MLX/FastVideo/LTX runtime has its own upstream source and dependency licences.
- Model weights are not part of GenStudio's source licence. Every model recipe must retain its own publisher licence and distribution terms.

Before attaching any runtime or binary to a public GitHub release, create a complete, reviewed third-party-notices bundle and verify that each component is redistributable in that form. See [the release guide](docs/OPEN_SOURCE_RELEASE.md).
