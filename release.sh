#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="${ROOT_DIR}/build/Recon.app"
ZIP_PATH="${ROOT_DIR}/build/Recon.app.zip"

"${ROOT_DIR}/build.sh"

rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

printf 'Created %s\n' "${ZIP_PATH}"
