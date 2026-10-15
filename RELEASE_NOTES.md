# GenStudio v0.1.0-source

This is the first public, source-first snapshot of GenStudio: a local-first visual AI workflow studio for Apple Silicon Macs.

## Included

- native macOS app source, XcodeGen specification, tests, scripts, and public technical documentation;
- node and workflow documentation for contributors and coding assistants;
- MIT licence for GenStudio-authored source; and
- explicit credit to HeliosGen, which inspired the original experiment.

## Deliberately not included

- model weights;
- the multi-gigabyte local-inference runtime and its binaries; and
- any Apple signing certificate, provisioning profile, notarization credential, Apple Team ID, private path, local cache, or original development Git history.

The source can compile and its tests can run on a supported Mac. Local inference cannot be set up from this release alone; a future release must provide a licence-reviewed runtime bootstrap with checksums and third-party notices. There is no signed or notarized installer in this release.

See [README.md](README.md) for the project overview and [docs/OPEN_SOURCE_RELEASE.md](docs/OPEN_SOURCE_RELEASE.md) for the publication and runtime-delivery plan.
