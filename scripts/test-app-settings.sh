#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/tests"
HARNESS_BIN="$BUILD_DIR/app-settings-harness"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK_PATH" \
  -framework ServiceManagement \
  -o "$HARNESS_BIN" \
  "$ROOT_DIR/Sources/Recon/Models/AppNotificationEvent.swift" \
  "$ROOT_DIR/Sources/Recon/Models/KubeconfigPreferenceMode.swift" \
  "$ROOT_DIR/Sources/Recon/Models/PollingIntervalOption.swift" \
  "$ROOT_DIR/Sources/Recon/Services/LaunchAtLoginManager.swift" \
  "$ROOT_DIR/Sources/Recon/Services/AppSettingsFileStore.swift" \
  "$ROOT_DIR/Sources/Recon/Services/AppSettingsStore.swift" \
  "$ROOT_DIR/Tests/AppSettingsStoreHarness.swift"

"$HARNESS_BIN"
