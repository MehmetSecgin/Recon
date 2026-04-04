#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/tests"
HARNESS_BIN="$BUILD_DIR/command-history-harness"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR"

SOURCE_FILES=(${(f)"$(find "$ROOT_DIR/Sources/Recon" -name '*.swift' ! -name 'ReconApp.swift' | sort)"})

xcrun swiftc \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK_PATH" \
  -framework UserNotifications \
  -lsqlite3 \
  -o "$HARNESS_BIN" \
  "${SOURCE_FILES[@]}" \
  "$ROOT_DIR/Tests/CommandHistoryHarness.swift"

"$HARNESS_BIN"
