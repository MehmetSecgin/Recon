#!/usr/bin/env bash

set -euo pipefail

REPO="${RECON_REPO:-mehmetsecgin/Recon}"
APP_NAME="Recon.app"
ASSET_NAME="${APP_NAME}.zip"
INSTALL_DIR="${RECON_INSTALL_DIR:-$HOME/Applications}"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/${ASSET_NAME}"

TMP_DIR="$(mktemp -d)"
ZIP_PATH="${TMP_DIR}/${ASSET_NAME}"
UNPACK_DIR="${TMP_DIR}/unpacked"

cleanup() {
  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

echo "Fetching latest Recon release from ${REPO}..."

mkdir -p "${INSTALL_DIR}" "${UNPACK_DIR}"

echo "Downloading ${ASSET_NAME}..."
curl -fL "${ASSET_URL}" -o "${ZIP_PATH}"

echo "Installing ${APP_NAME} to ${INSTALL_DIR}..."
ditto -x -k "${ZIP_PATH}" "${UNPACK_DIR}"

if [[ ! -d "${UNPACK_DIR}/${APP_NAME}" ]]; then
  echo "The downloaded archive did not contain ${APP_NAME} at its top level." >&2
  exit 1
fi

rm -rf "${INSTALL_DIR:?}/${APP_NAME}"
ditto "${UNPACK_DIR}/${APP_NAME}" "${INSTALL_DIR}/${APP_NAME}"
xattr -dr com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}" >/dev/null 2>&1 || true

open "${INSTALL_DIR}/${APP_NAME}" || true

echo "Installed ${APP_NAME} to ${INSTALL_DIR}/${APP_NAME}"
