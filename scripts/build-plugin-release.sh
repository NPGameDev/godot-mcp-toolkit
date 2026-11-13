#!/usr/bin/env bash
# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin/godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect), holding the release file list
# (release_files.sha256), and dist-plugin/godot-mcp-toolkit-<version>.update.json,
# the update manifest that pins the zip by size and hash. The manifest is unsigned.
# For a release, scripts/sign-release.sh writes the manifest again itself, from the zip
# and the tag, and signs that one; it reads no manifest it is handed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=lib/compatible_server.sh
source "${REPO_ROOT}/scripts/lib/compatible_server.sh"

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

# .uid sidecars (Godot 4.4+) are project state that must travel WITH the addon. A
# script shipped without one gets a new random uid on each machine after each update,
# which breaks `uid://` references to it and leaves a file in the addon folder that no
# release listed.
MISSING_UID="$(rf_scripts_without_uid "${STAGE}/addons/godot_mcp_toolkit")"
if [[ -n "${MISSING_UID}" ]]; then
  echo "error: every scanned script must ship with its .uid sidecar. Open the project in Godot 4.4+ to mint it, and commit it. Missing for:" >&2
  echo "${MISSING_UID}" | sed 's/^/  /' >&2
  exit 1
fi

MIN_GODOT="$(rf_min_godot "${REPO_ROOT}")"
if [[ -z "${MIN_GODOT}" ]]; then
  echo "error: could not read GODOT_MIN_VERSION from addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd." >&2
  exit 1
fi

COMPATIBLE_SERVER="$(cs_current "${REPO_ROOT}")" || COMPATIBLE_SERVER=""
if [[ -z "${COMPATIBLE_SERVER}" ]]; then
  echo "error: could not read COMPATIBLE_SERVER_VERSION from ${CS_CONSTANT_FILE}." >&2
  exit 1
fi

EXPIRES_AT="$(rf_expires_at "${REPO_ROOT}")" || {
  echo "error: could not read HEAD's commit time, which sets the manifest's expires_at (is this a git checkout with a commit?)." >&2
  exit 1
}

# The list of the release's files, inside the zip: it names every file a zip may hold but itself,
# and its hashes show a hand-edited file.
rf_write_list "${STAGE}/addons/godot_mcp_toolkit"

rm -f "${OUT_DIR}/${ZIP_NAME}"
(cd "${STAGE}" && zip -qr "../${ZIP_NAME}" addons)
rm -rf "${STAGE}"

MANIFEST_NAME="godot-mcp-toolkit-${VERSION}.update.json"
rf_write_manifest "${OUT_DIR}/${ZIP_NAME}" "${VERSION}" "${MIN_GODOT}" "${COMPATIBLE_SERVER}" "${EXPIRES_AT}" "${OUT_DIR}/${MANIFEST_NAME}"

echo "Built ${OUT_DIR}/${ZIP_NAME}"
echo "Built ${OUT_DIR}/${MANIFEST_NAME} (unsigned; scripts/sign-release.sh writes and signs a release's own)"
