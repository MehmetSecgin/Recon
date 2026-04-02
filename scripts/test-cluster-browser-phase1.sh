#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/tests"
HARNESS_BIN="$BUILD_DIR/cluster-browser-phase1-harness"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -target "${ARCH}-apple-macos14.0" \
  -sdk "$SDK_PATH" \
  -o "$HARNESS_BIN" \
  "$ROOT_DIR/Sources/Recon/Models/ClusterBrowserModels.swift" \
  "$ROOT_DIR/Sources/Recon/Models/ClusterBrowserLogic.swift" \
  "$ROOT_DIR/Sources/Recon/Models/ClusterBrowserSorting.swift" \
  "$ROOT_DIR/Sources/Recon/Models/ClusterBrowserDecoding.swift" \
  "$ROOT_DIR/Tests/ClusterBrowserPhase1Harness.swift"

"$HARNESS_BIN"
