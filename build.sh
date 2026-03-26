#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/Recon.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
ICON_SOURCE_DIR="$ROOT_DIR/Resources/AppIcon.appiconset"
ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
ICON_FILE="$RESOURCES_DIR/AppIcon.icns"

SOURCE_FILES=(
  "$ROOT_DIR/Sources/Recon/ReconApp.swift"
  "$ROOT_DIR/Sources/Recon/TelepresenceCLI.swift"
  "$ROOT_DIR/Sources/Recon/TelepresenceController.swift"
)

rm -rf "$APP_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

cp "$ICON_SOURCE_DIR/16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SOURCE_DIR/32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SOURCE_DIR/32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SOURCE_DIR/64.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SOURCE_DIR/128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SOURCE_DIR/256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SOURCE_DIR/256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SOURCE_DIR/512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SOURCE_DIR/512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SOURCE_DIR/1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

xcrun swiftc \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -o "$MACOS_DIR/Recon" \
  "${SOURCE_FILES[@]}"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

printf 'Built %s\n' "$APP_DIR"
