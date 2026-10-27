#!/usr/bin/env bash
# scripts/test_framework/check_release_builds.sh
# Checks that the two release builds write the same release: build-plugin-release.sh
# (bash) and build-plugin-release.ps1 (PowerShell) each build the plugin zip and its
# update manifest from this tree, and the two must hold the same entries with the
# same bytes, the same release file list, and manifests that agree on everything but
# the zip's own size and hash, each of which must match its own zip. The zips' bytes
# differ (compression and timestamps), which the toolkit never compares, and so do
# their folder entries: zip -r writes one per folder and the PowerShell build none,
# and the toolkit's archive check skips them (update/release_archive.gd).
#
# Usage: scripts/test_framework/check_release_builds.sh
# Exit 0 = the builds agree, 1 = they differ, 2 = setup error.
#
# Needs bash, zip, PowerShell 7 (pwsh) and Python 3. Writes only dist-plugin/ and a
# scratch folder it deletes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=../lib/update_test_env.sh
source "${REPO_ROOT}/scripts/lib/update_test_env.sh"

PYTHON_BIN="$(ut_python_bin)" || { echo "ERROR: Python 3 is required" >&2; exit 2; }
for tool in zip pwsh; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} is required" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release_builds.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

VERSION="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${REPO_ROOT}/addons/godot_mcp_toolkit/plugin.cfg" | tr -d '\r')"
ZIP_NAME="godot-mcp-toolkit-${VERSION}.zip"
MANIFEST_NAME="godot-mcp-toolkit-${VERSION}.update.json"

# Each build writes the same names into dist-plugin/, so each output is copied away
# before the other build runs.
build() {
  local label="$1"
  shift
  mkdir -p "${WORK}/${label}"
  (cd "${REPO_ROOT}" && "$@") > "${WORK}/${label}.log" 2>&1 \
    || { cat "${WORK}/${label}.log"; echo "ERROR: the ${label} build failed" >&2; exit 2; }
  cp "${REPO_ROOT}/dist-plugin/${ZIP_NAME}" "${REPO_ROOT}/dist-plugin/${MANIFEST_NAME}" "${WORK}/${label}/"
}

build bash bash scripts/build-plugin-release.sh
build pwsh pwsh -NoProfile -File scripts/build-plugin-release.ps1

"${PYTHON_BIN}" - "${WORK}/bash" "${WORK}/pwsh" "${ZIP_NAME}" "${MANIFEST_NAME}" <<'PY'
import hashlib
import json
import os
import sys
import zipfile

bash_dir, pwsh_dir, zip_name, manifest_name = sys.argv[1:5]
failed = False


def check(ok, message):
    global failed
    print(("  PASS " if ok else "  FAIL ") + message)
    failed = failed or not ok


def entries(folder):
    with zipfile.ZipFile(os.path.join(folder, zip_name)) as archive:
        return {info.filename: archive.read(info.filename)
                for info in archive.infolist() if not info.is_dir()}


def manifest(folder):
    with open(os.path.join(folder, manifest_name), encoding="utf-8") as text:
        return json.load(text)


bash_entries, pwsh_entries = entries(bash_dir), entries(pwsh_dir)
check(sorted(bash_entries) == sorted(pwsh_entries),
      "the zips hold the same files (%d)" % len(bash_entries))
only_bash = sorted(set(bash_entries) - set(pwsh_entries))
only_pwsh = sorted(set(pwsh_entries) - set(bash_entries))
if only_bash or only_pwsh:
    print("    only in the bash zip: %s" % only_bash[:10])
    print("    only in the PowerShell zip: %s" % only_pwsh[:10])
differing = sorted(name for name in set(bash_entries) & set(pwsh_entries)
                   if bash_entries[name] != pwsh_entries[name])
check(not differing, "every file has the same bytes in both zips")
if differing:
    print("    differing: %s" % differing[:10])
list_entry = "addons/godot_mcp_toolkit/release_files.sha256"
check(list_entry in bash_entries, "the zips carry the release file list")

bash_manifest, pwsh_manifest = manifest(bash_dir), manifest(pwsh_dir)
own_fields = ("archive_size", "archive_sha256")
shared = {key: value for key, value in bash_manifest.items() if key not in own_fields}
check(shared == {key: value for key, value in pwsh_manifest.items() if key not in own_fields}
      and set(bash_manifest) == set(pwsh_manifest),
      "the manifests agree on every field but the zip's size and hash")
for label, folder, data in (("bash", bash_dir, bash_manifest), ("PowerShell", pwsh_dir, pwsh_manifest)):
    path = os.path.join(folder, zip_name)
    with open(path, "rb") as archive:
        digest = hashlib.sha256(archive.read()).hexdigest()
    check(data.get("archive_sha256") == digest and data.get("archive_size") == os.path.getsize(path),
          "the %s manifest names its own zip's size and hash" % label)

sys.exit(1 if failed else 0)
PY
status=$?
if [[ ${status} -ne 0 ]]; then
  echo "RESULT: FAIL — the bash and PowerShell builds differ"
  exit 1
fi
echo "RESULT: PASS — the bash and PowerShell builds write the same release"
