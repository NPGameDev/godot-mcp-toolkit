# shellcheck shell=bash
#
# scripts/lib/release_files.sh: the two files a release publishes for the toolkit's
# self-update: the file list inside its zip and the update manifest beside it.
#
# Sourced, never run. The formats are a contract with the toolkit's update/ readers:
# keep them in step.
#
#   rf_sha256 <file>                    print the file's SHA-256, lowercase hex
#   rf_write_list <addon-dir>           write <addon-dir>/release_files.sha256: one
#                                       "<sha256>  <path>" line per file, paths
#                                       relative to the folder, byte-sorted, the
#                                       list itself left out (sha256sum's format)
#   rf_scripts_without_uid <addon-dir>  print each scanned .gd with no .uid sidecar,
#                                       relative to the folder, byte-sorted
#   rf_min_godot <repo-root>            print GODOT_MIN_VERSION from the version
#                                       utils, the oldest Godot the toolkit runs on
#   rf_expires_at <repo-root>           print the manifest's expiry: HEAD's commit
#                                       time plus RF_EXPIRY_SECONDS; return 1 when
#                                       the commit time cannot be read
#   rf_write_manifest <zip> <version> <min-godot> <compatible-server> <expires-at> <out>
#                                       write the update manifest for <zip>

RF_LIST_NAME="release_files.sha256"
RF_EXPIRY_SECONDS=15552000 # 180 days

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

# The engine skips a folder holding a .gdignore and everything under it, so it never
# gives those scripts a uid and they need no sidecar.
rf_scripts_without_uid() {
  local dir="$1" path parent ignored
  (cd "${dir}" && find . -type f -name '*.gd' | sed 's|^\./||' | LC_ALL=C sort) | while IFS= read -r path; do
    [[ -f "${dir}/${path}.uid" ]] && continue
    ignored=0
    parent="${path}"
    while [[ "${parent}" == */* ]]; do
      parent="${parent%/*}"
      [[ -e "${dir}/${parent}/.gdignore" ]] && ignored=1
    done
    [[ -e "${dir}/.gdignore" ]] && ignored=1
    [[ "${ignored}" -eq 1 ]] || printf '%s\n' "${path}"
  done
}

rf_min_godot() {
  sed -nE 's/^const GODOT_MIN_VERSION := "([^"]+)".*/\1/p' \
    "$1/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd" | tr -d '\r'
}

# Commit time, never the clock: a rebuild of the same commit writes the same bytes.
rf_expires_at() {
  local committed
  committed="$(git -C "$1" log -1 --format=%ct HEAD 2>/dev/null | tr -d '\r')" || return 1
  [[ "${committed}" =~ ^[0-9]+$ ]] || return 1
  echo "$((committed + RF_EXPIRY_SECONDS))"
}

# "format" changes only for a breaking change, after a bridge release: the reader
# requires an exact match, so a bump makes every older client refuse all updates.
# New keys are additive and leave it alone.
rf_write_manifest() {
  local zip="$1" version="$2" min_godot="$3" compatible_server="$4" expires_at="$5" out="$6"
  local size
  size="$(wc -c < "${zip}" | tr -d ' ')"
  printf '{"format": 1, "version": "%s", "archive": "%s", "archive_size": %s, "archive_sha256": "%s", "min_godot": "%s", "compatible_server": "%s", "expires_at": %s}\n' \
    "${version}" "$(basename "${zip}")" "${size}" "$(rf_sha256 "${zip}")" "${min_godot}" "${compatible_server}" "${expires_at}" > "${out}"
}
