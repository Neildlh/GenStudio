# Open-source release guide

This is the release checklist for publishing GenStudio as a free, source-first GitHub project. It is deliberately conservative: publishing source is irreversible in practice, and a public repository must not expose an Apple developer identity, private local paths, credentials, model weights, or unreviewed third-party binaries.

## Release position

The proposed public message is simple: **GenStudio is a free local-first macOS source project for visual AI workflows.** People may inspect, build, adapt, and contribute to it under the licence selected before publication. It is not yet a public signed-app download.

The source page must distinguish three things:

1. GenStudio source code and documentation.
2. Third-party runtimes and model weights, which have separate licence and redistribution terms.
3. A future signed/notarized macOS binary, which is optional and must not use the author's Apple signing identity unless the author chooses to distribute it.

## Pre-publication blockers

Do **not** make the existing Git history public yet. The tracked history contains Apple Team-ID material and local absolute paths in research, evidence, and task documents. Removing a value from the current files does not remove it from earlier commits.

Also, a fresh clone cannot currently complete the runtime-dependent build because the 8+ GB `.vendor/` directory is ignored. GitHub blocks regular Git files over 100 MiB and recommends repositories remain below 1 GB; it is not an appropriate place for this runtime or model weights. The public release needs a reproducible runtime bootstrap, checksums, and a licence review before it can promise `git clone` → working generation.

## What to publish

Publish the reviewed source tree, tests, XcodeGen specification, package lockfiles, scripts, the concise canonical docs, and the public community files below.

| File or feature | Purpose |
|---|---|
| `README.md` | Main GitHub page: purpose, capabilities, platform, honest source-build status, and links. |
| `LICENSE` | MIT licence for GenStudio-authored code. It gives downstream users broad reuse rights while retaining the notice and warranty disclaimer. |
| `ATTRIBUTIONS.md` | Credit HeliosGen and preserve/refer to upstream notices. |
| `CONTRIBUTING.md` | How to make a focused, test-backed change. |
| `CODE_OF_CONDUCT.md` | Community behaviour and moderation expectations. |
| `SECURITY.md` | Private vulnerability reporting route and security boundaries. |
| `SUPPORT.md` | Where questions, bugs, and ideas belong. |
| `.github/` templates | Consistent issue and pull-request reports; enable Discussions if you want a public questions space. |
| A release tag and notes | A fixed source snapshot and an honest statement of what does and does not work. |

Recommended GitHub repository metadata:

- **Description:** `A local-first visual AI workflow studio for Apple Silicon Macs.`
- **Topics:** `macos`, `swiftui`, `apple-silicon`, `local-ai`, `generative-ai`, `node-editor`, `image-generation`, `video-generation`, `mlx`, `on-device-ai`.
- **Website:** leave blank until there is a real project site; link the README/documentation rather than inventing one.
- **Social preview:** use a 1280×640 screenshot that shows the canvas and says “Local-first visual AI workflows for Apple Silicon.” Do not include personal information, model weights, or an unverified performance claim.

Topics, a concise description, a social preview, a focused README, release notes, and clear licences make the project easier to understand when someone lands on it from GitHub search, a topic page, a shared link, or a search engine. They do not guarantee ranking.

## Apple identity and signing

The published project must contain no hard-coded `DEVELOPMENT_TEAM`, Developer ID certificate, private key, provisioning profile, notary credential, or exported signed identity. The Team ID has been removed from the current XcodeGen source; regenerating the project removes it from the generated project too.

For a source build, a contributor chooses their own team in Xcode only if their configuration/capabilities require one. Apple notes that a macOS app can run on the developer's own Mac without signing setup when it does not require provisioned capabilities. A future public binary is a separate choice: it must be signed and notarized using a deliberate distribution identity, and that identity must never be committed.

## Provenance and licence review

Before choosing the source licence, make a one-time written inventory:

1. Name the original inspiration repository and its exact commit/tag.
2. Identify each file copied or adapted from it, if any.
3. Retain its copyright and licence text beside the affected material or in a reviewed notices file.
4. List every vendored runtime/binary, its upstream URL, revision, licence, and whether redistribution is allowed.
5. List models separately; do not imply that an app-source licence covers model weights.
6. Remove or exclude development fixtures, downloaded weights, local run artifacts, and historical research captures that contain private paths.

GenStudio-authored code uses the MIT licence so people can broadly reuse, modify, distribute, and commercialise their derivative work. It does not remove the duty to preserve the notices and conditions of code or binaries that came from elsewhere. GitHub also warns that licence guidance is not legal advice.

## Make a clean public repository

Use a **new, clean public Git history** rather than pushing this working repository's existing history. This is the safest practical option because the current history contains private local-path and Team-ID material.

1. Finish the public-source audit above.
2. Create a fresh directory from the reviewed public file set, excluding `.git`, `.build/`, `.vendor/`, local caches, downloaded models, and private research/evidence/task archives.
3. Run secret scanning on the new directory and inspect it for local paths, Team IDs, Apple credentials, tokens, archives, and large files.
4. Initialize a new Git repository and make the first commit only after the licence and notices are in place.
5. Create an empty **public** GitHub repository without GitHub's starter README, then add it as the remote and push the clean history.
6. In GitHub, set the description/topics/social preview, enable Issues and optionally Discussions, review the Community profile, and turn on available secret scanning, Dependabot alerts, and dependency review.
7. Tag the reviewed source release (for example `v0.1.0-source`) and publish release notes that state it is a source release—not a signed application—and name the runtime/model setup status.

Do not use a force-push or history-rewrite on this working repository without first making a separate backup and explicitly deciding that every existing collaborator/clone can be invalidated. A new public history is simpler and avoids accidentally restoring sensitive history.

## Runtime delivery decision

Choose one before the first public release:

| Option | What people receive | Requirement |
|---|---|---|
| Source-only first release | App source and a documented non-generation build/test path | Clearly say that local runtime generation setup is not yet published. |
| Reproducible bootstrap | Source plus a script that downloads/builds pinned redistributable runtimes from upstream with checksums | Review every upstream licence, support offline/failed download behaviour, and test from a clean clone. |
| Separate release assets | Source plus reviewed, signed or unsigned runtime archives below GitHub's per-file release-asset limit | Publish notices/checksums and decide whether users need Gatekeeper instructions. |

Model weights should remain separate from every option. The app should fetch only model recipes that the user chooses and whose terms they can review.

## First public release checklist

- [x] Root MIT `LICENSE` added for GenStudio-authored code.
- [ ] HeliosGen attribution and every applicable upstream notice reviewed.
- [x] Clean public history created; no Apple Team ID, private path, keys, profiles, or credentials remain.
- [ ] Fresh-clone build/test path verified on an Apple Silicon Mac.
- [ ] Runtime delivery path and third-party notices verified, or source-only limitation stated prominently.
- [ ] README screenshots and social preview reviewed for privacy and accuracy.
- [ ] GitHub description, topics, issue templates, contribution rules, support/security routes, and release notes configured.
- [ ] Tag and source release published.

## Sources

- [GitHub: About README files](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
- [GitHub: Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)
- [GitHub: Large-file limits and releases](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)
- [GitHub: Setting up healthy contributions](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions)
- [Apple: Build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Apple: Running a macOS app on your Mac](https://developer.apple.com/documentation/xcode/building-and-running-an-app)
