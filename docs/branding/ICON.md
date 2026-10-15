# GenStudio — Orbit

13 September 2026.

An original orbital assistant: a midnight-blue spherical face with luminous eyes and one ivory orbit, on a vivid tangerine tile. Bold forms keep the face recognisable in the Dock and small Finder icons. The artwork has transparent outside corners.

Generated with the built-in image generation tool. No local GenStudio inference engine was used to make the branding. The original transparent generation is the selected master; subsequent background-cleanup attempts produced opaque checkerboards and were rejected.

## Files

- `docs/branding/genstudio-orbit-master.png`: selected generated master, 1254 × 1254 RGBA.
- `GenStudio/Assets.xcassets/AppIcon.appiconset`: the ten native macOS 1×/2× entries (16 through 512 points, up to 1024 pixels).
- `project.yml`: explicit AppIcon asset-catalog setting.

The source is copied into this repository. Icon sizes are mechanically downsampled with macOS `sips`; no illustration or content is added by code. Xcode's asset compiler emits the application icon and bundle metadata. All future normal builds include the icon.

## Generation prompt

Use case: logo-brand. Asset type: final macOS application icon for GenStudio, a private local AI creative workflow studio. Create ONE polished square app icon artwork, not a presentation or mockup. Art direction: an original stylised futuristic assistant globe/face, sophisticated and friendly, a very simple dark midnight-navy spherical head with two short luminous ice-white eyes; no mouth. One clean thick orbital band curves around the globe at a slight diagonal, evoking creative intelligence and connected workflows. Subtle sculptural 3D volume, restrained satin ceramic finish, strong bold silhouette and generous negative space. Bright vivid tangerine-orange background in a rounded-square macOS icon tile, very subtle warm gradient only. The tile occupies 90% of a square 1024x1024 canvas, centered with gently rounded superellipse corners, with genuinely transparent outside corners and margin; keep a restrained soft tile shadow inside canvas. The globe and orbit occupy approximately 65% of tile width and are fully contained within it. Front-facing character, carefully balanced symmetric eyes, modern premium industrial design, clean readable forms that work at 32 pixels. No words, letters, logos, watermark, tiny circuitry, star fields, extra objects, busy HUD rings, photoreal human features, or recognizable superhero helmet. Deliver finished icon only.

## Verification and installation

All ten PNG entries passed dimension and alpha-channel checks. Native `actool` compilation succeeded without warnings (`.build/icon-assets/compile.log`) and produced AppIcon.icns, Assets.car and the correct CFBundleIconFile/CFBundleIconName metadata. Small 32px and 128px versions were visually inspected.

To avoid rebuilding another task's in-progress workflow sources, the compiled icon resources and icon plist keys were applied to the existing `.build/DerivedData/Build/Products/Debug/GenStudio.app`. Its previous Info.plist and signing metadata were retained under `.build/icon-assets/`. The application was re-signed with its existing entitlements and passed `codesign --verify --deep --strict`. Launch Services was refreshed. The running app was deliberately not restarted; its Dock icon may refresh on its next normal relaunch. The other task's canonical build will include the catalog through XcodeGen's existing recursive GenStudio source directory.
