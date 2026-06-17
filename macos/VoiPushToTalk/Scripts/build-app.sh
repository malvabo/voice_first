#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Voi.app"
BIN="$ROOT/.build/release/VoiPushToTalk"
ICON_SRC="$(cd "$ROOT/.." && pwd)/../assets/voi-icon.svg"
ICON_WORK="$ROOT/.build/icon-work"
ICONSET="$ICON_WORK/Voi.iconset"
ICON_PNG="$ICON_WORK/voi-icon.png"
ICON_ICNS="$ICON_WORK/Voi.icns"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

rm -rf "$ICON_WORK"
mkdir -p "$ICONSET"

qlmanage -t -s 1024 -o "$ICON_WORK" "$ICON_SRC" >/dev/null 2>&1
GENERATED_ICON="$(find "$ICON_WORK" -maxdepth 1 -name '*.png' | head -n 1)"
if [[ -z "$GENERATED_ICON" ]]; then
  echo "error: failed to rasterize app icon from $ICON_SRC" >&2
  exit 1
fi
mv "$GENERATED_ICON" "$ICON_PNG"

sips -z 16 16     "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICON_ICNS"

cp "$BIN" "$APP/Contents/MacOS/Voi"
cp "$ROOT/Resources/PersonInDarkRoom.jpg" "$APP/Contents/Resources/PersonInDarkRoom.jpg"
cp "$ICON_ICNS" "$APP/Contents/Resources/Voi.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Voi</string>
  <key>CFBundleIdentifier</key>
  <string>app.voi.push-to-talk</string>
  <key>CFBundleIconFile</key>
  <string>Voi.icns</string>
  <key>CFBundleName</key>
  <string>Voi</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Voi records while you hold fn/Globe so it can transcribe and paste your dictated text.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Voi listens for the fn/Globe push-to-talk shortcut so it can record while held.</string>
</dict>
</plist>
PLIST

IDENTITY="${VOI_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -n 1)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with stable identity: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: no valid code-signing identity found; signing ad-hoc."
  echo "         macOS permissions can reset after rebuilds."
  echo "         Install an Apple Development certificate or set VOI_SIGN_IDENTITY."
  codesign --force --sign - "$APP"
fi

echo "$APP"
