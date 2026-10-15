#!/bin/bash
set -euo pipefail
# Make the vendored MLX Python runtime load only code that ships inside it.
#
# The runtime is a venv built from a Homebrew framework Python, so the copied
# tree still referred to /opt/homebrew by absolute path: the framework's own
# interpreter and its Python.app stub loaded the Cellar copy of Python, and five
# stdlib extension modules loaded Homebrew's OpenSSL, SQLite, xz and mpdecimal.
# Inside a signed app those loads are refused - the Homebrew binaries carry a
# different Team ID than the app - which is the "Python cannot be opened because
# of a problem" dialog, and on a Mac without Homebrew they are simply missing.
#
# This rewrites every absolute dependency to a @loader_path-relative one and
# vendors the external dylibs into the framework. It is idempotent: a tree that
# is already relocated produces no changes, so it is safe to run on both the
# .vendor source tree and the copy staged inside the app bundle.
runtime_root="${1:?usage: relocate_python_runtime.sh <runtime-root>}"
framework="$runtime_root/lib/Python.framework/Versions/3.13"
support_directory="$framework/lib/genstudio-dylibs"
test -f "$framework/Python"

# install_name_tool invalidates the signature it rewrites, and macOS kills a
# Mach-O whose signature no longer matches, so every edited file is re-signed
# ad-hoc immediately. Release packaging re-signs the tree afterwards with the
# app's real identity; an ad-hoc signature keeps the runtime runnable in between.
reseal() { /usr/bin/codesign --force --sign - --timestamp=none "$1" >/dev/null 2>&1; }
# Rewrite load commands on an unsigned file. Wheels ship signed binaries, and
# install_name_tool prints "changes being made to the file will invalidate the
# code signature" for each one - Xcode reports every such line as a build
# warning. Dropping the signature first makes the edit silent; reseal follows.
edit_load_commands() {
    local file="${@: -1}"
    /usr/bin/codesign --remove-signature "$file" >/dev/null 2>&1 || true
    /usr/bin/install_name_tool "$@"
}
relative_path() { /usr/bin/python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }
# Dependencies outside /usr/lib and /System are the ones that will not exist -
# or will not be loadable - on a machine other than this build host. A dylib's
# own install name is listed by otool alongside its dependencies and must be
# ignored: wheels shipped by delocate carry deliberately unresolvable ids such
# as /DLC/scipy/.dylibs/libquadmath.0.dylib or /opt/llvm-openmp/lib/libomp.dylib
# and are loaded by their dependents through @loader_path, not through that id.
external_dependencies() {
    local own_id
    own_id="$(/usr/bin/otool -D "$1" | /usr/bin/tail -1)"
    /usr/bin/otool -L "$1" | /usr/bin/tail -n +2 | /usr/bin/awk '{ print $1 }' \
        | /usr/bin/grep -E '^/' | /usr/bin/grep -v -E '^(/usr/lib|/System)/' \
        | /usr/bin/grep -v -x -F "$own_id" || true
}

# 1. The framework's own dylib, and the two executables that load it. The venv
#    launcher in bin/ already uses @rpath and needs no change.
if /usr/bin/otool -D "$framework/Python" | /usr/bin/tail -1 | /usr/bin/grep -q '^/'; then
    edit_load_commands -id "@rpath/Python.framework/Versions/3.13/Python" "$framework/Python"
    reseal "$framework/Python"
fi
for framework_client in "$framework/bin/python3.13" "$framework/Resources/Python.app/Contents/MacOS/Python"; do
    test -f "$framework_client" || continue
    for dependency in $(external_dependencies "$framework_client"); do
        case "$dependency" in
            */Python.framework/Versions/3.13/Python)
                edit_load_commands -change "$dependency" \
                    "@loader_path/$(relative_path "$framework/Python" "$(dirname "$framework_client")")" "$framework_client"
                reseal "$framework_client" ;;
        esac
    done
done

# 2. Everything else: vendor the external dylib next to the framework and point
#    the loader at the copy. Copied dylibs are processed the same way, so a
#    dependency chain (libssl -> libcrypto) is followed to the end.
vendor_dependency() {
    local dependency="$1" resolved name
    resolved="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dependency")"
    name="$(basename "$resolved")"
    if [ ! -f "$support_directory/$name" ]; then
        mkdir -p "$support_directory"
        /usr/bin/ditto "$resolved" "$support_directory/$name"
        chmod u+w "$support_directory/$name"
        edit_load_commands -id "@loader_path/$name" "$support_directory/$name"
        relocate_file "$support_directory/$name"
        reseal "$support_directory/$name"
    fi
    printf '%s' "$name"
}

relocate_file() {
    local file="$1" dependency name
    for dependency in $(external_dependencies "$file"); do
        case "$dependency" in
            */Python.framework/Versions/3.13/Python) continue ;;
        esac
        name="$(vendor_dependency "$dependency")"
        chmod u+w "$file"
        edit_load_commands -change "$dependency" \
            "@loader_path/$(relative_path "$support_directory/$name" "$(dirname "$file")")" "$file"
        reseal "$file"
    done
}

while IFS= read -r -d '' candidate; do
    case "$candidate" in
        "$support_directory"/*) continue ;;
    esac
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then relocate_file "$candidate"; fi
done < <(/usr/bin/find "$runtime_root" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0)

# 3. Make the interpreter itself look inside the runtime for extension modules.
#    A venv's pyvenv.cfg names its base Python by absolute path, and the path
#    baked in at build time cannot be right once the runtime is copied into an
#    app that can live anywhere. When it does not resolve, Python falls back to
#    its compiled-in Homebrew location and loads Homebrew's _ssl, _sqlite3,
#    _lzma and _decimal from there instead of the copies vendored above. That
#    works on the build machine and fails in the signed app. sys.base_prefix is
#    always right, because it comes from where libpython actually loaded, so a
#    .pth line puts the bundled lib-dynload first on sys.path.
cat > "$runtime_root/lib/python3.13/site-packages/genstudio-runtime.pth" <<'PTH'
import os, sys; sys.path.insert(0, os.path.join(sys.base_prefix, 'lib', 'python3.13', 'lib-dynload'))
PTH

remaining="$(/usr/bin/find "$runtime_root" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 \
    | /usr/bin/xargs -0 -P 8 -n 40 /bin/sh -c 'for file; do
        own_id="$(/usr/bin/otool -D "$file" 2>/dev/null | /usr/bin/tail -1)"
        if /usr/bin/otool -L "$file" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/awk "{ print \$1 }" \
            | /usr/bin/grep -v -x -F "$own_id" | /usr/bin/grep -qE "^/(opt|usr/local)/"; then echo "$file"; fi
      done' _ | /usr/bin/head -5)"
if [ -n "$remaining" ]; then
    echo "relocate_python_runtime: still loading code from outside the runtime:" >&2
    echo "$remaining" >&2
    exit 1
fi
# 4. Prove it by behaviour. Load-command inspection cannot see a path Python
#    chooses at runtime, and an ad-hoc signed Homebrew module loads without
#    complaint until the app is signed with Hardened Runtime, so import the
#    modules that were relocated and require every loaded file to live inside
#    the runtime (or be part of macOS). -B keeps the sealed bundle unmodified.
RUNTIME_ROOT="$runtime_root" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 "$runtime_root/bin/python" -B - <<'CHECK'
import os, sys
import ssl, sqlite3, lzma, decimal, hashlib, zlib, bz2, ctypes  # noqa: F401
root = os.path.realpath(os.environ["RUNTIME_ROOT"])
outside = sorted({
    os.path.realpath(module.__file__)
    for module in list(sys.modules.values())
    if os.path.isabs(getattr(module, "__file__", None) or "")
    and not os.path.realpath(module.__file__).startswith((root + os.sep, "/System/", "/usr/lib/"))
})
if outside:
    raise SystemExit("relocate_python_runtime: Python loaded modules from outside the runtime:\n  " + "\n  ".join(outside))
CHECK
echo "relocate_python_runtime: $runtime_root loads only its own code"
