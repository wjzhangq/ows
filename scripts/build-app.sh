#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

BIN=".build/release/OWABridge"
APP="build/OWA Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OWABridge"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Sources/OWABridgeCore/Resources/extractor.js "$APP/Contents/Resources/extractor.js"

shopt -s nullglob
for bundle in .build/release/*OWABridgeCore*.bundle; do
  cp -R "$bundle" "$APP/Contents/MacOS/"
done

chmod +x "$APP/Contents/MacOS/OWABridge"
if command -v codesign >/dev/null 2>&1; then
  for bundle in "$APP/Contents/MacOS/"*.bundle; do
    [ -e "$bundle" ] || continue
    codesign --force --sign - "$bundle"
  done
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
