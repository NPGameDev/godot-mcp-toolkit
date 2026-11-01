#!/usr/bin/env bash
# Build the AssetLib-distributable plugin zip from addons/godot_mcp_toolkit/.
# Output: dist-plugin/godot-mcp-toolkit-<version>.zip (zip's top entry is
# `addons/godot_mcp_toolkit/`, matching what both AssetLib and a manual
# extract-into-addons install expect), holding the release file list
# (release_files.sha256), and dist-plugin/godot-mcp-toolkit-<version>.update.json,
# the update manifest the toolkit's self-update reads. The manifest is unsigned:
# the maintainer signs it with scripts/sign-release.sh (docs/dev/release-runbook.md).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

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

# Ship .uid sidecars (Godot 4.4+): they are project state that must travel WITH
# the addon, or `uid://` references to addon files break on update. We must NOT
# strip them — keep the staged tree identical to the git tree and the AssetLib
# archive. Regression guard: a future re-introduction of any
# `.uid` strip would empty the staged tree and must break the build loudly.
UID_COUNT="$(find "${STAGE}/addons/godot_mcp_toolkit" -name "*.uid" | wc -l)"
if [[ "${UID_COUNT}" -eq 0 ]]; then
  echo "error: .uid sidecars must ship — none found in staged tree (${STAGE}). Do not strip *.uid from the addon." >&2
  exit 1
fi

MIN_GODOT="$(rf_min_godot "${REPO_ROOT}")"
if [[ -z "${MIN_GODOT}" ]]; then
  echo "error: could not read GODOT_MIN_VERSION from addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd." >&2
  exit 1
fi

# The list of the release's files: the self-update deletes only files an installed
# release listed, and spots the ones changed by hand.
rf_write_list "${STAGE}/addons/godot_mcp_toolkit"

rm -f "${OUT_DIR}/${ZIP_NAME}"
(cd "${STAGE}" && zip -qr "../${ZIP_NAME}" addons)
rm -rf "${STAGE}"

MANIFEST_NAME="godot-mcp-toolkit-${VERSION}.update.json"
rf_write_manifest "${OUT_DIR}/${ZIP_NAME}" "${VERSION}" "${MIN_GODOT}" "${OUT_DIR}/${MANIFEST_NAME}"

echo "Built ${OUT_DIR}/${ZIP_NAME}"
echo "Built ${OUT_DIR}/${MANIFEST_NAME} (unsigned; sign it with scripts/sign-release.sh)"
