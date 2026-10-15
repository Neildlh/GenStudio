#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="GenStudio"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
SOURCE_PACKAGES="$ROOT_DIR/.build/SourcePackages"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/GenStudio.app"

mkdir -p "$ROOT_DIR/.build"
project_signature="$({ /usr/bin/shasum -a 256 "$ROOT_DIR/project.yml"; /usr/bin/find "$ROOT_DIR/GenStudio" "$ROOT_DIR/GenStudioTests" -type f -name '*.swift' -print | /usr/bin/sort; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
signature_file="$ROOT_DIR/.build/xcodegen-inputs.sha256"
if [ ! -f "$ROOT_DIR/GenStudio.xcodeproj/project.pbxproj" ] || [ ! -f "$signature_file" ] || [ "$(cat "$signature_file")" != "$project_signature" ]; then
    xcodegen generate --spec "$ROOT_DIR/project.yml"
    printf '%s' "$project_signature" > "$signature_file"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodebuild -quiet -project "$ROOT_DIR/GenStudio.xcodeproj" -scheme GenStudio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" build

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs) open_app; exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "studio.gen.GenStudio"' ;;
  --verify|verify) open_app; for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null && exit 0; sleep 0.25; done; echo "GenStudio did not remain running" >&2; exit 1 ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
