#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="$ROOT_DIR/.vendor"
RUNTIME_PARENT="$HOME/Library/Application Support/GenStudio/RuntimeLibrary/Installed"
RUNTIME_DESTINATION="$RUNTIME_PARENT/native-2026-10-12"

complete_runtime() {
    local root="$1"
    test -x "$root/llama/bin/llama-cli" \
        && test -x "$root/llama/bin/llama-mtmd-cli" \
        && test -x "$root/sd/bin/sd-cli" \
        && test -x "$root/mlx-fastvideo/bin/python" \
        && test -x "$root/mlx-fastvideo/bin/genstudio-mlx-vlm" \
        && test -x "$root/mlx-fastvideo/bin/genstudio-fastmetal-5b" \
        && test -x "$root/mlx-fastvideo/bin/genstudio-ltx-23" \
        && test -x "$root/mlx-fastvideo/bin/genstudio-mlx-tts" \
        && test -f "$root/mlx-fastvideo/RUNTIME.lock"
}

if complete_runtime "$RUNTIME_DESTINATION"; then
    echo "GenStudio local runtime is already installed."
    exit 0
fi
complete_runtime "$SOURCE_ROOT"

mkdir -p "$RUNTIME_PARENT"
STAGING="$(mktemp -d "$RUNTIME_PARENT/.staging.XXXXXX")"
cleanup() { test ! -d "$STAGING" || rm -rf "$STAGING"; }
trap cleanup EXIT

for engine in llama sd; do
    mkdir -p "$STAGING/$engine"
    for part in bin lib licenses; do
        /usr/bin/ditto "$SOURCE_ROOT/$engine/$part" "$STAGING/$engine/$part"
    done
done
/usr/bin/ditto "$SOURCE_ROOT/mlx-fastvideo" "$STAGING/mlx-fastvideo"
complete_runtime "$STAGING"

if [ -e "$RUNTIME_DESTINATION" ]; then
    BACKUP="$RUNTIME_PARENT/.previous.$(date +%s)"
    mv "$RUNTIME_DESTINATION" "$BACKUP"
    if mv "$STAGING" "$RUNTIME_DESTINATION"; then
        rm -rf "$BACKUP"
    else
        mv "$BACKUP" "$RUNTIME_DESTINATION"
        exit 1
    fi
else
    mv "$STAGING" "$RUNTIME_DESTINATION"
fi

# Earlier app-owned runtimes are superseded by this package; LocalRuntimeLibrary removes them the same way.
for previous in "$RUNTIME_PARENT"/native-*; do
    test -d "$previous" && test "$previous" != "$RUNTIME_DESTINATION" && rm -rf "$previous"
done
echo "Installed GenStudio local runtime at $RUNTIME_DESTINATION"
