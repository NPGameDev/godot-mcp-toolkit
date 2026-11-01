#!/usr/bin/env bash
# scripts/check_release_files.sh
# Checks a built release against its list and manifest, once its zip has been
# unzipped into a project and booted:
#   1. Every file release_files.sha256 lists is in the tree, unchanged.
#   2. The tree holds nothing the list leaves out, other than the engine's *.import.
#      An update replaces the whole addon folder, so a plugin that writes there loses
#      the file on the next update; it fails here, and so does a .uid the engine minted
#      for a shipped file that lacks one.
#   3. The tree's list is the zip's, byte for byte: a list edited after the build could
#      otherwise vouch for a file the release never held.
#   4. The manifest's size and hash match the zip, its archive name is the zip's, and
#      its version is the one in the name and in the tree's plugin.cfg.
#
# Usage: bash scripts/check_release_files.sh <zip> <manifest> <unzipped-addon-dir>
# Exit 0 = clean, 1 = a check failed, 2 = setup error (a wrong call, no unzip)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: check_release_files.sh <zip> <manifest> <unzipped-addon-dir>" >&2
  exit 2
fi
ZIP="$1"
MANIFEST="$2"
TREE="$3"
for path in "${ZIP}" "${MANIFEST}"; do
  [[ -f "${path}" ]] || { echo "ERROR: no file at ${path}" >&2; exit 2; }
done
[[ -d "${TREE}" ]] || { echo "ERROR: no folder at ${TREE}" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip is required" >&2; exit 2; }

fail=0
problem() {
  echo "  FAIL: $*" >&2
  fail=1
}

hash_check() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${RF_LIST_NAME}"
  else
    shasum -a 256 -c "${RF_LIST_NAME}"
  fi
}

# One tree path per line, byte-sorted, without the list and the engine's *.import.
tree_files() {
  (cd "${TREE}" && find . -type f) | sed 's|^\./||' | grep -v '\.import$' | grep -vxF "${RF_LIST_NAME}" | LC_ALL=C sort
}

listed_files() {
  sed -E 's/^[0-9a-f]{64}  //' "${TREE}/${RF_LIST_NAME}" | LC_ALL=C sort
}

# Reads one key of the manifest's single line, quoted or not.
manifest_field() {
  sed -nE "s/.*\"$1\": *\"?([^\",}]*)\"?.*/\1/p" "${MANIFEST}" | tr -d '\r'
}

echo "check:release-files — the tree against ${RF_LIST_NAME}"
if [[ ! -f "${TREE}/${RF_LIST_NAME}" ]]; then
  problem "no ${RF_LIST_NAME} in ${TREE}"
else
  if report="$(cd "${TREE}" && hash_check 2>&1)"; then
    echo "  ok: every listed file is unchanged"
  else
    problem "a listed file changed or is missing:"
    printf '%s\n' "${report}" | grep -v ': OK$' | sed 's/^/    /' >&2
  fi
  extras="$(LC_ALL=C comm -23 <(tree_files) <(listed_files))"
  if [[ -z "${extras}" ]]; then
    echo "  ok: nothing unlisted but *.import"
  else
    problem "files the list leaves out (a plugin writing into its own folder, or a .uid the engine minted):"
    printf '%s\n' "${extras}" | sed 's/^/    /' >&2
  fi
  if unzip -p "${ZIP}" "addons/godot_mcp_toolkit/${RF_LIST_NAME}" 2>/dev/null | cmp -s - "${TREE}/${RF_LIST_NAME}"; then
    echo "  ok: the list is the zip's"
  else
    problem "the tree's ${RF_LIST_NAME} is not the zip's"
  fi
fi

echo "check:release-files — the manifest against the zip"
zip_size="$(wc -c < "${ZIP}" | tr -d ' ')"
if [[ "$(manifest_field archive_size)" == "${zip_size}" ]]; then
  echo "  ok: archive_size ${zip_size}"
else
  problem "manifest archive_size is '$(manifest_field archive_size)', the zip has ${zip_size} bytes"
fi
zip_hash="$(rf_sha256 "${ZIP}")"
if [[ "$(manifest_field archive_sha256)" == "${zip_hash}" ]]; then
  echo "  ok: archive_sha256 ${zip_hash}"
else
  problem "manifest archive_sha256 is '$(manifest_field archive_sha256)', the zip hashes to ${zip_hash}"
fi
zip_name="$(basename "${ZIP}")"
if [[ "$(manifest_field archive)" == "${zip_name}" ]]; then
  echo "  ok: archive ${zip_name}"
else
  problem "manifest archive is '$(manifest_field archive)', the zip is ${zip_name}"
fi
version="$(manifest_field version)"
tree_version="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${TREE}/plugin.cfg" 2>/dev/null | tr -d '\r')"
if [[ -n "${version}" && "${tree_version}" == "${version}" && "${zip_name}" == "godot-mcp-toolkit-${version}.zip" ]]; then
  echo "  ok: version ${version}"
else
  problem "manifest version is '${version}', the zip is ${zip_name} and its plugin.cfg says '${tree_version}'"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "check:release-files — FAIL" >&2
  exit 1
fi
echo "check:release-files — PASS"
