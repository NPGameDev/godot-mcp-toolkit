# shellcheck shell=bash
#
# scripts/lib/release_files.sh: the files a release publishes for the toolkit's
# self-update, beside its zip.
#
# Sourced, never run: scripts/build-plugin-release.sh writes both files with it,
# and the self-update's end-to-end tests build their test installs the same way
# (scripts/lib/update_test_env.sh).
#
#   rf_sha256 <file>                    print the file's SHA-256, lowercase hex
#   rf_write_list <addon-dir>           write <addon-dir>/release_files.sha256: one
#                                       "<sha256>  <path>" line per file, paths
#                                       relative to the folder, byte-sorted, the
#                                       list itself left out (sha256sum's format)
#   rf_min_godot <repo-root>            print GODOT_MIN_VERSION from the version
#                                       utils, the oldest Godot the toolkit runs on
#   rf_write_manifest <zip> <version> <min-godot> <out>
#                                       write the update manifest for <zip>
#
# The toolkit reads both (addons/godot_mcp_toolkit/update/release_file_list.gd and
# release_manifest.gd); keep the formats in step with those readers.

RF_LIST_NAME="release_files.sha256"

rf_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

rf_write_list() {
  local dir="$1" path
  local list="${dir}/${RF_LIST_NAME}"
  rm -f "${list}"
  # Hash each file on its own so a name never reaches sha256sum's escaping. The
  # list is written beside the files while find walks them, so it skips its own
  # temporary file.
  (cd "${dir}" && find . -type f ! -name "${RF_LIST_NAME}.tmp" | sed 's|^\./||' | LC_ALL=C sort) | while IFS= read -r path; do
    printf '%s  %s\n' "$(rf_sha256 "${dir}/${path}")" "${path}"
  done > "${list}.tmp"
  mv "${list}.tmp" "${list}"
}

rf_min_godot() {
  sed -nE 's/^const GODOT_MIN_VERSION := "([^"]+)".*/\1/p' \
    "$1/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd" | tr -d '\r'
}

rf_write_manifest() {
  local zip="$1" version="$2" min_godot="$3" out="$4"
  local size
  size="$(wc -c < "${zip}" | tr -d ' ')"
  printf '{"format": 1, "version": "%s", "archive": "%s", "archive_size": %s, "archive_sha256": "%s", "min_godot": "%s"}\n' \
    "${version}" "$(basename "${zip}")" "${size}" "$(rf_sha256 "${zip}")" "${min_godot}" > "${out}"
}
