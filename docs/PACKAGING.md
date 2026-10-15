# Packaging GenStudio

Release builds ship local engines (`llama`, `sd`) and a self-contained managed MLX runtime inside `GenStudio.app/Contents/Resources/LocalRuntimes`, with their licences. Debug builds deliberately omit that directory: Models → Start Here installs the same pinned runtime once at `~/Library/Application Support/GenStudio/RuntimeLibrary/Installed/native-2026-10-12`, keeping everyday builds small and fast. The MLX runtime includes a relocated Python framework plus narrow Qwen, FastMetal, and LTX launchers and a bundled ffmpeg used by LTX video encoding; users do not install Python, Homebrew, uv or developer tools. Model weights are never bundled and are downloaded by the app into `~/Library/Application Support/GenStudio/ModelLibrary`.

## Version

Set once in `project.yml`. XcodeGen writes both values into the generated Info.plist for Debug and Release.

| Setting | Info.plist key | First beta |
|---|---|---|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | `0.1.0` |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | `1` |

Increase `CURRENT_PROJECT_VERSION` for every build you hand out, then run `xcodegen generate --spec project.yml`.

## Signing model

The Release app is built with the **Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES` for Release only). Debug is unhardened for local debugging.

`script/package_local_runtimes.sh` verifies and copies the Release engines, then re-signs their frameworks, dylibs and executables with the same identity Xcode uses for the app. Xcode runs this post-build phase after its ordinary app signing step, so the script re-seals the outer bundle after nested code is added or changed. The MLX source contract is frozen by `.vendor/mlx-fastvideo/RUNTIME.lock` and `requirements.lock`; `script/verify_mlx_runtime.sh` must pass before packaging.

- **Ad-hoc identity (`-`):** the engines are signed without the Hardened Runtime. Hardened Runtime library validation requires an executable and its dylibs to share a Team ID. Ad-hoc code has no Team ID, so hardened ad-hoc engines refuse to load their own libraries (verified with dyld's "different Team IDs" error). The app itself is still hardened.
- **Real identity (Developer ID):** the engines get `--options runtime --timestamp`, which notarization requires. They share the app's Team ID, so library validation passes. Local Release packaging is verified, but the Developer ID export/notarization path still requires its own verification; see below.
- **Stamp:** the script skips runtimes whose sources and signing options are unchanged. That keeps incremental builds from re-signing nested code after Xcode has sealed the app.

Check `LocalRuntimes/*/licenses` and the packaged Python distributions' licence metadata in every package you distribute. The LTX launcher and packages are pinned to `dgrauet/ltx-2-mlx` v0.16.3, commit `ae3b7ea9583db775bd4a1dfb506fb789585021e7`. `mlx-fastvideo/share/genstudio-aux` carries FastMetal's TAEHV decoder and RIFE 4.25 interpolator weights (MIT; `licenses/taehv-LICENSE`, `licenses/rife-mlx-LICENSE`).

## A. Local beta (local development signing or ad-hoc)

Use this path for this Mac or trusted testers. An ad-hoc package is rejected by Gatekeeper (`spctl` reports "rejected"); a locally development-signed package is still not a Developer ID/notarized public distribution.

```bash
xcodegen generate --spec project.yml
rm -rf .build/Beta
xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/Beta build
APP=.build/Beta/Build/Products/Release/GenStudio.app

# Verify
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority|flags" # ad-hoc shows adhoc; local signing shows its development authority
R="$APP/Contents/Resources/LocalRuntimes"
"$R/llama/bin/llama-cli" --version && "$R/llama/bin/llama-mtmd-cli" --version && "$R/sd/bin/sd-cli" --help | head -2
script/verify_mlx_runtime.sh "$R/mlx-fastvideo"

# Package
/usr/bin/ditto -c -k --keepParent "$APP" GenStudio-0.1.0-1.zip
```

Testers on another Mac must open the app with Control-click → Open, or use System Settings → Privacy & Security → Open Anyway. Always use a clean build (as above) for anything you hand out.

## B. Developer ID + notarization (public distribution)

**Blocked until the owner provides:**
- a **Developer ID Application** certificate with private key in the login keychain;
- notary credentials: an App Store Connect API key, or an Apple ID with an app-specific password.

The project has a development team for local automatic signing, but no Developer ID Application certificate or notary credentials are configured in this repository.

1. **Store notary credentials once:**
   ```bash
   xcrun notarytool store-credentials GenStudioNotary --team-id TEAMID --apple-id you@example.com
   # or: --key AuthKey_XXXX.p8 --key-id XXXX --issuer ISSUER-UUID
   ```
2. **Archive**, signed with Developer ID. Pass the team on the command line; don't commit it.
   ```bash
   xcodebuild -project GenStudio.xcodeproj -scheme GenStudio -configuration Release \
     -destination 'generic/platform=macOS' -archivePath .build/GenStudio.xcarchive archive \
     DEVELOPMENT_TEAM=TEAMID CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application"
   ```
3. **Export.** Create `.build/ExportOptions.plist` with `method` = `developer-id`, `teamID` = `TEAMID` and `signingStyle` = `manual`, then run:
   ```bash
   xcodebuild -exportArchive -archivePath .build/GenStudio.xcarchive \
     -exportOptionsPlist .build/ExportOptions.plist -exportPath .build/Export
   APP=.build/Export/GenStudio.app
   ```
4. **Verify before submitting.** These checks are required because the Developer ID path is untested.
   ```bash
   codesign --verify --deep --strict --verbose=2 "$APP"
   codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "TeamIdentifier|flags|Timestamp"
   for f in "$APP"/Contents/Resources/LocalRuntimes/*/{bin/*,lib/*.dylib}; do codesign -dv --verbose=4 "$f" 2>&1 | grep -E "TeamIdentifier|flags"; done
   R="$APP/Contents/Resources/LocalRuntimes"
   "$R/llama/bin/llama-cli" --version && "$R/llama/bin/llama-mtmd-cli" --version && "$R/sd/bin/sd-cli" --help | head -2
   script/verify_mlx_runtime.sh "$R/mlx-fastvideo"
   ```
   Expected result:
   - every nested file shows the same `TeamIdentifier` as the app, plus `runtime` and a timestamp;
   - the three native CLIs print their version or usage and the MLX verifier confirms exact imports, launchers and self-contained links.

   If export changed the nested signatures or an engine fails to load, fix the signing first. Do **not** add `com.apple.security.cs.disable-library-validation` as a workaround.
5. **Notarize and staple:**
   ```bash
   /usr/bin/ditto -c -k --keepParent "$APP" .build/GenStudio-notarize.zip
   xcrun notarytool submit .build/GenStudio-notarize.zip --keychain-profile GenStudioNotary --wait
   xcrun stapler staple "$APP"
   spctl --assess --type execute -vv "$APP"     # expect: accepted, source=Notarized Developer ID
   /usr/bin/ditto -c -k --keepParent "$APP" GenStudio-0.1.0-1.zip
   ```
   If notarization fails, read the log with `xcrun notarytool log <submission-id> --keychain-profile GenStudioNotary`.

   One known risk: the engines are Mach-O executables under `Contents/Resources`. Apple recommends `Contents/Helpers` or `Contents/MacOS` for executables. If the notary log or `codesign` objects, move them there and update `NativeRuntime.executable`.
