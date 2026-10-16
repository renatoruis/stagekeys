#!/bin/bash
set -euo pipefail
SRC="${SRCROOT}/Resources"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/StageLibrary"
mkdir -p "$(dirname "${DEST}")"
rsync -a --delete --exclude '.DS_Store' "${SRC}/" "${DEST}/"
find "${DEST}" -name '.DS_Store' -delete

PLUGINS="${TARGET_BUILD_DIR}/${PLUGINS_FOLDER_PATH}"
if [ -d "${SRCROOT}/Plugins" ]; then
  mkdir -p "${PLUGINS}"
  rsync -a --delete --exclude '.DS_Store' "${SRCROOT}/Plugins/" "${PLUGINS}/"
else
  rm -rf "${PLUGINS}"
fi
