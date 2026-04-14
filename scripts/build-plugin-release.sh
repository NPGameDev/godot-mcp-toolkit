#!/usr/bin/env bash
# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin/godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PLUGIN_CFG="addons/godot_mcp_toolkit/plugin.cfg"
if [[ ! -f "${PLUGIN_CFG}" ]]; then
  echo "error: ${PLUGIN_CFG} not found (run from toolkit-repo root)." >&2
  exit 1
fi

VERSION="$(grep -E '^version="' "${PLUGIN_CFG}" | sed -E 's/version="([^"]+)".*/\1/')"
if [[ -z "${VERSION}" ]]; then
  echo "error: could not read version from ${PLUGIN_CFG}." >&2
  exit 1
fi

OUT_DIR="dist-plugin"
STAGE="${OUT_DIR}/stage"
ZIP_NAME="godot-mcp-toolkit-${VERSION}.zip"

rm -rf "${STAGE}"
mkdir -p "${STAGE}/addons"
cp -r addons/godot_mcp_toolkit "${STAGE}/addons/godot_mcp_toolkit"

# Drop .uid files — they are editor-managed per-project and shouldn't ship.
find "${STAGE}/addons/godot_mcp_toolkit" -name "*.uid" -delete

rm -f "${OUT_DIR}/${ZIP_NAME}"
(cd "${STAGE}" && zip -qr "../${ZIP_NAME}" addons)
rm -rf "${STAGE}"

echo "Built ${OUT_DIR}/${ZIP_NAME}"
