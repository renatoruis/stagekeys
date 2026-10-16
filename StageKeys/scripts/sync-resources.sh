#!/bin/bash
set -euo pipefail
# Sounds are downloaded at runtime; remove the SF2 copy left by older builds.
rm -rf "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/StageLibrary"

PLUGINS="${TARGET_BUILD_DIR}/${PLUGINS_FOLDER_PATH}"
if [ -d "${SRCROOT}/Plugins" ]; then
  mkdir -p "${PLUGINS}"
  rsync -a --delete --exclude '.DS_Store' "${SRCROOT}/Plugins/" "${PLUGINS}/"
else
  rm -rf "${PLUGINS}"
fi
