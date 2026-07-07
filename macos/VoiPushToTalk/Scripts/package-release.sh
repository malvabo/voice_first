#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Voi.app"
ARTIFACT_DIR="$ROOT/.build/release-artifacts"
ZIP="$ARTIFACT_DIR/Voi-macOS-arm64.zip"
CHECKSUM="$ZIP.sha256"

export COPYFILE_DISABLE=1

cd "$ROOT"
"$ROOT/Scripts/build-app.sh"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$CHECKSUM"

echo "Created:"
echo "  $ZIP"
echo "  $CHECKSUM"

if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
  echo "codesign verification: ok"
else
  echo "warning: codesign verification failed for $APP" >&2
  echo "         Private testers may need to right-click Open." >&2
  echo "         Public distribution needs Developer ID signing and Apple notarization." >&2
fi
