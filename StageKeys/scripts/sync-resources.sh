#!/bin/bash
set -euo pipefail
SRC="${SRCROOT}/Resources"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/StageLibrary"
mkdir -p "$(dirname "${DEST}")"
rsync -a --delete --exclude '.DS_Store' "${SRC}/" "${DEST}/"
find "${DEST}" -name '.DS_Store' -delete
