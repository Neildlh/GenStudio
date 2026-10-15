#!/bin/bash
set -euo pipefail
# Executed by Xcode before signing the outer application bundle. Models are never bundled.
# Nested runtime code is re-signed inside-out (libraries, then executables) with the same identity Xcode uses for the
# app, so the outer signature seals consistently signed code.
# Hardened Runtime on the engines is applied only with a real signing identity. Its library validation requires the
# executable and its dylibs to share a Team ID; ad-hoc ("-") signatures have none, so hardened ad-hoc engines fail to
# load their own libraries (verified: dyld "different Team IDs"). A Developer ID identity gets runtime + timestamp,
# which notarization requires. The outer app follows ENABLE_HARDENED_RUNTIME from project.yml.
runtime_destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/LocalRuntimes"
runtime_stamp_output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/.local-runtime-packaging.stamp"
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
signing_options=(--force --sign "$signing_identity")
if [ "$signing_identity" = "-" ]; then
    signing_options+=(--timestamp=none)
else
    signing_options+=(--timestamp)
    if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then signing_options+=(--options runtime); fi
fi

# Debug builds use the one-time runtime installation managed from Models →
# Start Here. Keeping 1.3 GB of Python/MLX code outside the product bundle makes
# clean UI builds fast while Release retains the signed bundled fallback.
if [ "${GENSTUDIO_BUNDLE_LOCAL_RUNTIMES:-YES}" != "YES" ]; then
    rm -rf "$runtime_destination"
    mkdir -p "$(dirname "$runtime_stamp_output")"
    printf 'external-runtime\n' > "$runtime_stamp_output"
    plugins_directory="${CODESIGNING_FOLDER_PATH:?}/Contents/PlugIns"
    if [ -d "$plugins_directory" ]; then
        # A completed test action leaves its xctest bundle in the same app
        # product. Remove it before ordinary development launches; during a
        # test action Xcode recreates the test bundle after this app phase.
        /usr/bin/find "$plugins_directory" -mindepth 1 -maxdepth 1 -type d -name '*.xctest' -exec /bin/rm -rf {} +
    fi
    /usr/bin/codesign --deep "${signing_options[@]}" "${CODESIGNING_FOLDER_PATH:?}"
    /usr/bin/codesign --verify --strict "${CODESIGNING_FOLDER_PATH:?}"
    exit 0
fi
test -x "${SRCROOT:?}/.vendor/llama/bin/llama-mtmd-cli"
test -f "${SRCROOT:?}/.vendor/llama/lib/libmtmd.0.dylib"
for runtime_engine in llama sd; do
    runtime_source="${SRCROOT:?}/.vendor/$runtime_engine"
    test -d "$runtime_source/bin" && test -d "$runtime_source/lib" && test -d "$runtime_source/licenses"
    # Skip unchanged runtimes: re-signing after Xcode has sealed the app (an incremental build that skips CodeSign)
    # would invalidate the outer signature, and timestamped signatures differ on every run.
    runtime_stamp="${TARGET_TEMP_DIR:?}/local-runtime-$runtime_engine.signing-stamp"
    expected_stamp="$( (cd "$runtime_source" && /usr/bin/find bin lib licenses -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256; echo "${signing_options[*]}") | /usr/bin/shasum -a 256)"
    if [ -f "$runtime_stamp" ] && [ -d "$runtime_destination/$runtime_engine/bin" ] && [ "$(cat "$runtime_stamp")" = "$expected_stamp" ]; then
        for runtime_file in "$runtime_destination/$runtime_engine/lib/"*.dylib "$runtime_destination/$runtime_engine/bin/"*; do
            /usr/bin/codesign --verify --strict "$runtime_file"
        done
        continue
    fi
    rm -rf "$runtime_destination/$runtime_engine"
    mkdir -p "$runtime_destination/$runtime_engine"
    for runtime_part in bin lib licenses; do
        /usr/bin/ditto "$runtime_source/$runtime_part" "$runtime_destination/$runtime_engine/$runtime_part"
    done
    for runtime_file in "$runtime_destination/$runtime_engine/lib/"*.dylib "$runtime_destination/$runtime_engine/bin/"*; do
        /usr/bin/codesign "${signing_options[@]}" "$runtime_file"
        /usr/bin/codesign --verify --strict "$runtime_file"
    done
    mkdir -p "${TARGET_TEMP_DIR:?}"
    printf '%s' "$expected_stamp" > "$runtime_stamp"
done

# FastVideo's Apple path is a self-contained, ARM64 Python+MLX runtime. It is
# built under .vendor for release, then copied and signed as a private app
# resource. Do not replace this with a system/Homebrew Python at launch time.
mlx_engine="mlx-fastvideo"
mlx_source="${SRCROOT:?}/.vendor/$mlx_engine"
test -x "$mlx_source/bin/python"
test -x "$mlx_source/bin/genstudio-fastmetal-5b"
test -x "$mlx_source/bin/genstudio-mlx-vlm"
test -x "$mlx_source/bin/genstudio-ltx-23"
test -x "$mlx_source/bin/ffmpeg"
test -f "$mlx_source/licenses/ltx-2-mlx-LICENSE"
test -f "$mlx_source/RUNTIME.lock"
test -f "$mlx_source/requirements.lock"
test -f "$mlx_source/app/examples/inference/basic/mlx_wan22_generate.py"
test -f "$mlx_source/lib/Python.framework/Versions/3.13/Python"
"${SRCROOT:?}/script/verify_mlx_runtime.sh" "$mlx_source"
mlx_stamp="${TARGET_TEMP_DIR:?}/local-runtime-$mlx_engine.signing-stamp"
mlx_expected_stamp="$( (cd "$mlx_source" && /usr/bin/find bin lib app licenses RUNTIME.lock requirements.lock -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256; echo "${signing_options[*]}") | /usr/bin/shasum -a 256)"
if [ ! -f "$mlx_stamp" ] || [ ! -d "$runtime_destination/$mlx_engine" ] || [ "$(cat "$mlx_stamp")" != "$mlx_expected_stamp" ]; then
    rm -rf "$runtime_destination/$mlx_engine"
    mkdir -p "$runtime_destination"
    /usr/bin/ditto "$mlx_source" "$runtime_destination/$mlx_engine"
    # Bytecode caches are development residue, add substantial size, and may be
    # rewritten by Python after signing. Ship source modules and run Python with
    # bytecode writes disabled so the app bundle remains immutable.
    /usr/bin/find "$runtime_destination/$mlx_engine" -type d -name '__pycache__' -prune -exec /bin/rm -rf {} +
    /usr/bin/find "$runtime_destination/$mlx_engine" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
    # A framework-local site-packages bridge created by venv points outside
    # Python.framework and makes strict code-sign validation reject the bundle.
    # The private launcher already sets PYTHONPATH to the runtime's real
    # site-packages directory, so the bridge is unnecessary at runtime and must
    # not be shipped. Keep this exact-path removal here as a defence if the
    # vendor runtime is rebuilt by venv in the future.
    framework_site_packages="$runtime_destination/$mlx_engine/lib/Python.framework/Versions/3.13/lib/python3.13/site-packages"
    if [ -L "$framework_site_packages" ]; then /usr/bin/unlink "$framework_site_packages"; fi
    # The vendored runtime is a venv over a Homebrew framework Python, so its
    # copied framework and five stdlib extension modules can still name
    # /opt/homebrew by absolute path. Inside the signed app those loads are
    # refused - Homebrew's binaries carry a different Team ID - and on a Mac
    # without Homebrew they do not exist at all. Rewrite them to load the code
    # that ships in this bundle. Idempotent, so an already-relocated .vendor
    # tree makes this a no-op; it runs before the signing loop below because
    # rewriting a load command invalidates the signature it rewrites.
    "${SRCROOT:?}/script/relocate_python_runtime.sh" "$runtime_destination/$mlx_engine"
    # Sign all Mach-O payloads individually. Restrict inspection to dynamic
    # libraries and executable files: the runtime contains roughly 50,000 data
    # and Python source files, and invoking `file` once for every one of them
    # made a first Release package spend several minutes scanning non-code.
    # Python extension modules and MLX dylibs are nested below site-packages, so
    # the llama/sd flat-directory signing loop above is intentionally not reused.
    while IFS= read -r -d '' runtime_file; do
        if /usr/bin/file -b "$runtime_file" | /usr/bin/grep -q 'Mach-O'; then
            /usr/bin/codesign "${signing_options[@]}" "$runtime_file"
            /usr/bin/codesign --verify --strict "$runtime_file"
        fi
    done < <(/usr/bin/find "$runtime_destination/$mlx_engine" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0)
    mkdir -p "${TARGET_TEMP_DIR:?}"
    printf '%s' "$mlx_expected_stamp" > "$mlx_stamp"
fi

# Xcodegen places post-build scripts after Xcode's standard CodeSign phase.
# Re-seal the outer bundle after adding/re-signing the nested MLX payload so an
# incremental build cannot leave a valid executable with invalid resources.
outer_bundle="${CODESIGNING_FOLDER_PATH:?}"
# A test action pre-creates its future .xctest directory inside the app before
# this app-target phase runs. Until the test target writes Info.plist it is not
# a bundle and strict codesign rejects the whole app. Remove only that incomplete
# build placeholder; Xcode recreates and signs the real test bundle afterward.
plugins_directory="$outer_bundle/Contents/PlugIns"
if [ -d "$plugins_directory" ]; then
    while IFS= read -r -d '' test_bundle; do
        if [ ! -f "$test_bundle/Contents/Info.plist" ]; then rm -rf "$test_bundle"; fi
    done < <(/usr/bin/find "$plugins_directory" -mindepth 1 -maxdepth 1 -type d -name '*.xctest' -print0)
fi
printf 'bundled-runtime\n' > "$runtime_stamp_output"
# An Archive (install action) strips the app executable after this phase and
# always runs CodeSign last. Sealing here would only have strip break the seal
# and print "changes being made to the file will invalidate the code signature"
# per architecture, so leave the outer signature to Xcode's own final CodeSign.
if [ "${DEPLOYMENT_POSTPROCESSING:-NO}" = "YES" ]; then exit 0; fi
/usr/bin/codesign --deep "${signing_options[@]}" "$outer_bundle"
/usr/bin/codesign --verify --strict "$outer_bundle"
