#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Voi.app"
BIN="$ROOT/.build/release/VoiPushToTalk"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Voi"
cp "$ROOT/Resources/PersonInDarkRoom.jpg" "$APP/Contents/Resources/PersonInDarkRoom.jpg"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Voi</string>
  <key>CFBundleIdentifier</key>
  <string>app.voi.push-to-talk</string>
  <key>CFBundleName</key>
  <string>Voi</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Voi records while you hold Option-Space so it can transcribe and paste your dictated text.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Voi listens for the Option-Space push-to-talk shortcut so it can record while held.</string>
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
