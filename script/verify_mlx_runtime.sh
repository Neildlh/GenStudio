#!/bin/bash
set -euo pipefail

# Verify either the vendored source runtime or a runtime copied into an app.
# This is deliberately read-only. A damaged signed runtime is repaired by
# rebuilding/reinstalling GenStudio, never by mutating its app bundle in place.
runtime_root="${1:-${SRCROOT:-$(pwd)}/.vendor/mlx-fastvideo}"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONNOUSERSITE=1
test -f "$runtime_root/RUNTIME.lock"
test -f "$runtime_root/requirements.lock"
test -x "$runtime_root/bin/python"
test -x "$runtime_root/bin/genstudio-fastmetal-5b"
test -x "$runtime_root/bin/genstudio-mlx-vlm"
test -x "$runtime_root/bin/genstudio-ltx-23"
test -x "$runtime_root/bin/genstudio-mlx-tts"
test -x "$runtime_root/bin/ffmpeg"
test -f "$runtime_root/licenses/ltx-2-mlx-LICENSE"
test ! -f "$runtime_root/lib/python3.13/site-packages/ltx_core_mlx-0.16.3.dist-info/direct_url.json"
test ! -f "$runtime_root/lib/python3.13/site-packages/ltx_pipelines_mlx-0.16.3.dist-info/direct_url.json"
test -f "$runtime_root/app/examples/inference/basic/mlx_wan22_generate.py"
test -f "$runtime_root/app/genstudio_fastmetal.py"
test -f "$runtime_root/licenses/taehv-LICENSE"
test -f "$runtime_root/licenses/rife-mlx-LICENSE"
# FastMetal's TAEHV decoder and RIFE 4.25 interpolator ship with the runtime so a
# first or offline generation never downloads them (see share/genstudio-aux/MANIFEST).
aux_root="$runtime_root/share/genstudio-aux"
test -f "$aux_root/rife-4.25/config.json"
test "$(/usr/bin/shasum -a 256 "$aux_root/taehv/taew2_2.pth" | /usr/bin/awk '{ print $1 }')" = "d053e216ca50e2bb837bbcd79b85f0366bea00e5938025572382a773b74c559a"
test "$(/usr/bin/shasum -a 256 "$aux_root/rife-4.25/model.safetensors" | /usr/bin/awk '{ print $1 }')" = "40bd5bdc9b41d22ad2fad79da325dcd68988a90d8b8e8fb7b67ed5eedebccf5f"

expected_python="$(/usr/bin/awk -F= '$1 == "python" { print $2 }' "$runtime_root/RUNTIME.lock")"
actual_python="$("$runtime_root/bin/python" -B -c 'import platform; print(platform.python_version())')"
test "$actual_python" = "$expected_python"

"$runtime_root/bin/python" -B - <<'PY'
import importlib.metadata as metadata
expected = {
    "diffusers": "0.40.0",
    "mlx": "0.32.2",
    "mlx-vlm": "0.7.1",
    "torch": "2.12.0",
    "transformers": "5.15.1",
}
actual = {name: metadata.version(name) for name in expected}
if actual != expected:
    raise SystemExit(f"Pinned runtime mismatch: {actual}")
import diffusers, mlx, mlx_vlm, torch, transformers
print(f"GenStudio MLX runtime ready: {actual}")
PY

"$runtime_root/bin/python" -B - <<'PY'
import importlib.metadata as metadata
expected = {
    "ltx-core-mlx": "0.16.3",
    "ltx-pipelines-mlx": "0.16.3",
    "mlx-arsenal": "0.2.4",
    "mlx-lm": "0.31.1",
    "protobuf": "7.36.1",
}
actual = {name: metadata.version(name) for name in expected}
if actual != expected:
    raise SystemExit(f"Pinned LTX runtime mismatch: {actual}")
import ltx_core_mlx, ltx_pipelines_mlx, mlx_arsenal, mlx_lm
print(f"GenStudio LTX runtime ready: {actual}")
PY

RUNTIME_ROOT="$runtime_root" "$runtime_root/bin/python" -B - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["RUNTIME_ROOT"]).resolve()
for path in root.rglob("*"):
    if not path.is_symlink():
        continue
    try:
        target = path.resolve(strict=True)
    except FileNotFoundError:
        raise SystemExit(f"Broken runtime symlink: {path}")
    if not target.is_relative_to(root):
        raise SystemExit(f"Runtime symlink escapes bundle: {path} -> {target}")
print(f"Runtime symlinks are self-contained under {root}")
PY

"$runtime_root/bin/genstudio-fastmetal-5b" --help >/dev/null
"$runtime_root/bin/genstudio-mlx-vlm" --help >/dev/null
"$runtime_root/bin/genstudio-ltx-23" --help >/dev/null
"$runtime_root/bin/genstudio-mlx-tts" --help >/dev/null
"$runtime_root/bin/ffmpeg" -version >/dev/null
