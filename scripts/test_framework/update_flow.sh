#!/usr/bin/env bash
# scripts/test_framework/update_flow.sh
# Integration test of the toolkit's self-update, end to end, on scratch projects.
#
# The release under test is the zip and update manifest build-plugin-release.sh
# writes from this tree. The installed toolkit is the same tree one version older
# within the same major, trusting a key made for the run, with its release file list and one file only it
# has. A local HTTP server answers the update check's and the installer's requests
# in place of GitHub and the Asset Store (GODOT_MCP_UPDATE_CHECK_HOST). Each leg
# boots a headless editor (GODOT_MCP_UPDATE_ALLOW_HEADLESS=1) with the consent seen
# and the automatic mode, and a test-only plugin (test/update_driver/) quits it once
# the update is staged, so the toolkit's exit applies it; a second boot checks what
# the next start runs.
#
# Legs (UPDATE_FLOW_LEGS, default all):
#   full        the release is installed: the next start runs it, the dropped file
#               is gone, the record and the backup are deleted
#   rollback    a folder the release writes is read-only: the old version is back
#   untrusted   the manifest is signed by another key: nothing is staged
#   repository  the project holds the toolkit repository's marker: nothing happens
#   disable     the toolkit is disabled after staging: nothing is installed
#
# Usage: scripts/test_framework/update_flow.sh [godot-binary]
# Exit 0 = every leg passed, 1 = a leg failed, 2 = setup error.
#
# Environment variables:
#   GODOT_BIN         Godot binary (default: first arg, or "godot")
#   UPDATE_FLOW_LEGS  the legs to run, space-separated
#   UPDATE_FLOW_KEEP  set to 1 to keep the scratch folder for forensics
#   UPDATE_FLOW_SKIP_BUILD  set to 1 to test the zip and manifest already in
#                     dist-plugin/ instead of building them (the release workflow)
# Needs Python 3 (the HTTP server), openssl, GNU timeout (gtimeout on macOS) and,
# unless UPDATE_FLOW_SKIP_BUILD is set, zip. Runs everything under a scratch HOME
# (and, on Windows, a scratch %APPDATA%, where Godot keeps its files there), so the
# machine's own registry and editor settings are never touched. Runs on Linux, macOS
# and Windows (Git Bash); on Windows the rollback leg makes the write fail with a
# release file's read-only attribute (ut_set_read_only), since NTFS ignores chmod.
# A failed run prints each leg's editor logs, install log and record.

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-${1:-godot}}"
LEGS="${UPDATE_FLOW_LEGS:-full rollback untrusted repository disable}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=../lib/update_test_env.sh
source "${REPO_ROOT}/scripts/lib/update_test_env.sh"

OS="$(ut_os)"
PYTHON_BIN="$(ut_python_bin)" || { echo "ERROR: Python 3 is required" >&2; exit 2; }
TIMEOUT_BIN="$(ut_timeout_bin)"
TOOLS=(openssl "${TIMEOUT_BIN}")
[[ "${UPDATE_FLOW_SKIP_BUILD:-0}" == 1 ]] || TOOLS+=(zip)
for tool in "${TOOLS[@]}"; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} is required" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/update_flow.XXXXXX")"
SERVER_PID=""
READ_ONLY_FILE=""
cleanup() {
  [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
  [[ -n "${READ_ONLY_FILE}" ]] && ut_set_read_only "${READ_ONLY_FILE}" false
  chmod -R u+w "${WORK}" 2>/dev/null
  if [[ "${UPDATE_FLOW_KEEP:-0}" == 1 ]]; then
    echo "kept ${WORK}"
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

export HOME="${WORK}/home" XDG_DATA_HOME="${WORK}/home/.local/share" \
  XDG_CONFIG_HOME="${WORK}/home/.config" XDG_CACHE_HOME="${WORK}/home/.cache"
export GODOT_MCP_RUNTIME=0
mkdir -p "${HOME}"
if [[ "${OS}" == windows ]]; then
  mkdir -p "${HOME}/AppData/Roaming" "${HOME}/AppData/Local"
  APPDATA="$(cygpath -w "${HOME}/AppData/Roaming")"
  LOCALAPPDATA="$(cygpath -w "${HOME}/AppData/Local")"
  export APPDATA LOCALAPPDATA
fi

FAILED=0
fail() { echo "  FAIL [${LEG}] $*"; FAILED=1; }
pass() { echo "  PASS [${LEG}] $*"; }

# ── The release under test ──────────────────────────────────────────────────
if [[ "${UPDATE_FLOW_SKIP_BUILD:-0}" != 1 ]]; then
  (cd "${REPO_ROOT}" && bash scripts/build-plugin-release.sh) > "${WORK}/build.log" 2>&1 \
    || { cat "${WORK}/build.log"; echo "ERROR: build-plugin-release.sh failed" >&2; exit 2; }
fi
NEW_VERSION="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${REPO_ROOT}/addons/godot_mcp_toolkit/plugin.cfg" | tr -d '\r')"
RELEASE_ZIP="${REPO_ROOT}/dist-plugin/godot-mcp-toolkit-${NEW_VERSION}.zip"
RELEASE_MANIFEST="${REPO_ROOT}/dist-plugin/godot-mcp-toolkit-${NEW_VERSION}.update.json"
[[ -f "${RELEASE_ZIP}" && -f "${RELEASE_MANIFEST}" ]] || { echo "ERROR: no release zip or manifest for ${NEW_VERSION}" >&2; exit 2; }
# The installed version is one step older within the same major: a major release is
# only ever linked, never installed from the editor, so there is no flow to test.
OLD_VERSION="$(ut_previous_version "${NEW_VERSION}")"
if [[ -z "${OLD_VERSION}" ]]; then
  echo "SKIP: ${NEW_VERSION} is a major release, which the toolkit only links to; nothing to install."
  exit 0
fi
OLD_ONLY_FILE="update_flow_old_only.txt"

# ── Keys ────────────────────────────────────────────────────────────────────
ut_make_key "${WORK}/trusted.pem"
ut_make_key "${WORK}/other.pem"

# ── The installed toolkit, warmed once ──────────────────────────────────────
TEMPLATE="${WORK}/template"
ut_install_old_toolkit "${REPO_ROOT}" "${TEMPLATE}/addons/godot_mcp_toolkit" "${OLD_VERSION}" \
  "${WORK}/trusted.pub.pem" "${OLD_ONLY_FILE}"
cp -r "${REPO_ROOT}/test/update_driver" "${TEMPLATE}/addons/update_driver"

cat > "${TEMPLATE}/project.godot" <<'EOF'
config_version=5

[application]

config/name="Update Flow"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_mcp_toolkit/plugin.cfg", "res://addons/update_driver/plugin.cfg")

[mcp_toolkit]

updates/install_mode="automatic"
EOF
# run_units_cold.sh has the full story of the class cache Godot 4.2 needs.
ut_warm "${GODOT_BIN}" "${TEMPLATE}" "${WORK}/warm.log" \
  || { tail -30 "${WORK}/warm.log"; echo "ERROR: warm-up wrote no class cache" >&2; exit 2; }

# ── One leg ─────────────────────────────────────────────────────────────────
run_leg() {
  LEG="$1"
  local dir="${WORK}/${LEG}"
  local project="${dir}/project" server="${dir}/server"
  mkdir -p "${dir}"
  cp -r "${TEMPLATE}" "${project}"
  # A name of its own gives the leg its own user:// folder.
  sed -i.bak "s/config\/name=\"Update Flow\"/config\/name=\"Update Flow ${LEG}\"/" "${project}/project.godot" && rm -f "${project}/project.godot.bak"
  local addon="${project}/addons/godot_mcp_toolkit"

  local user_dir
  user_dir="$(ut_user_dir "${GODOT_BIN}" "${project}")"
  [[ -n "${user_dir}" ]] || { fail "could not read the project's user folder"; return; }
  local toolkit_user="${user_dir}/addons/godot_mcp_toolkit"
  echo "${toolkit_user}" > "${dir}/toolkit_user"
  ut_mark_setup_seen "${user_dir}"

  local signer="${WORK}/trusted.pem"
  [[ "${LEG}" == untrusted ]] && signer="${WORK}/other.pem"
  ut_stage_release "${server}" "${NEW_VERSION}" "${NEW_VERSION}" "${RELEASE_ZIP}" "${RELEASE_MANIFEST}" "${signer}"

  # A port of the leg's own: a server an earlier leg left behind holds no port this one
  # needs (on Windows, kill may not reach the Python process Git Bash started).
  local port
  port="$("${PYTHON_BIN}" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  export GODOT_MCP_EDITOR_PORT="$(( port % 1000 + 30000 ))"
  "${PYTHON_BIN}" -u -m http.server "${port}" --bind 127.0.0.1 --directory "${server}" > "${dir}/server.log" 2>&1 &
  SERVER_PID=$!
  # The editor's first request comes within seconds of its boot, so the editor boots
  # only once the server answers.
  local ready=0
  for _ in $(seq 1 50); do
    if "${PYTHON_BIN}" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${port}/repos/NPGameDev/godot-mcp-toolkit/releases/latest', timeout=1)" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.2
  done
  [[ ${ready} -eq 1 ]] || fail "the local server did not answer within 10 s"

  local timeout=90 disable=0
  case "${LEG}" in
    rollback)
      if [[ "${OS}" == windows ]]; then
        # A file the release changes: a failed write of one that already holds the
        # release's bytes reads back right, and the apply rightly counts it written.
        READ_ONLY_FILE="${addon}/plugin.cfg"
        ut_set_read_only "${READ_ONLY_FILE}" true
      else
        chmod 555 "${addon}/commands"
      fi
      ;;
    untrusted | repository) timeout=25 ;;
    disable) disable=1 ;;
  esac
  [[ "${LEG}" == repository ]] && mkdir -p "${project}/scripts" && touch "${project}/scripts/build-plugin-release.sh"

  GODOT_MCP_UPDATE_CHECK_HOST="http://127.0.0.1:${port}" GODOT_MCP_UPDATE_ALLOW_HEADLESS=1 \
    UPDATE_DRIVER_WAIT_FOR=staged UPDATE_DRIVER_TIMEOUT="${timeout}" UPDATE_DRIVER_DISABLE="${disable}" \
    "${TIMEOUT_BIN}" 180 "${GODOT_BIN}" --headless --editor --path "${project}" > "${dir}/boot1.log" 2>&1
  local boot1_status=$?
  kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
  if [[ -n "${READ_ONLY_FILE}" ]]; then
    ut_set_read_only "${READ_ONLY_FILE}" false
    READ_ONLY_FILE=""
  fi
  [[ "${LEG}" == rollback && "${OS}" != windows ]] && chmod u+w "${addon}/commands"

  local installed record log
  installed="$(sed -nE 's/^version="([^"]+)".*/\1/p' "${addon}/plugin.cfg" | tr -d '\r')"
  record="${toolkit_user}/update/pending_update.json"
  log="${toolkit_user}/update/install.log"
  [[ ${boot1_status} -eq 124 ]] && fail "the first boot hung past 180 s"

  if [[ "${LEG}" == full || "${LEG}" == rollback ]]; then
      grep -qF "[UPDATE-DRIVER] reached staged" "${dir}/boot1.log" && pass "the update was staged" || fail "the update was never staged"
      "${TIMEOUT_BIN}" 120 "${GODOT_BIN}" --headless --editor --path "${project}" --quit-after 900 > "${dir}/boot2.log" 2>&1
      local expected="${NEW_VERSION}"
      [[ "${LEG}" == rollback ]] && expected="${OLD_VERSION}"
      grep -qF "Godot MCP Toolkit v${expected} " "${dir}/boot2.log" && pass "the next start runs ${expected}" || fail "the next start does not run ${expected}"
      grep -qF "[MCPServer] listening" "${dir}/boot2.log" && pass "the next start's server listens" || fail "the next start's server does not listen"
      if grep -qE "SCRIPT ERROR|Parse Error" "${dir}/boot2.log"; then fail "the next start logs script errors"; else pass "the next start logs no script error"; fi
      [[ "${installed}" == "${expected}" ]] && pass "plugin.cfg reads ${expected}" || fail "plugin.cfg reads '${installed}', not ${expected}"
  fi

  case "${LEG}" in
    full)
      [[ ! -e "${addon}/${OLD_ONLY_FILE}" ]] && pass "the file the release dropped is gone" || fail "the dropped file is still there"
      grep -q "apply ${NEW_VERSION}: applied" "${log}" && pass "the install log says applied" || fail "the install log does not say applied"
      [[ ! -e "${record}" && ! -e "${toolkit_user}/update/backup" ]] && pass "the record and the backup are deleted" || fail "the record or the backup is left"
      ;;
    rollback)
      grep -q "apply ${NEW_VERSION}: rolled_back" "${log}" && pass "the install log says rolled back" || fail "the install log does not say rolled back"
      # The read-only folder's files never changed, so the restore skips them.
      if grep -q "were not restored" "${log}"; then fail "the restore reports files it did not need to write"; else pass "the restore left unchanged files alone"; fi
      [[ -e "${addon}/${OLD_ONLY_FILE}" ]] && pass "the old version's own file is back" || fail "the old version's own file is missing"
      ;;
    untrusted)
      grep -qF "[UPDATE-DRIVER] timeout waiting for staged" "${dir}/boot1.log" && pass "nothing was staged" || fail "the driver did not time out"
      grep -q "is not signed by a trusted key" "${log}" && pass "the install log names the untrusted signature" || fail "the install log does not name the signature"
      [[ "${installed}" == "${OLD_VERSION}" ]] && pass "the installed version is unchanged" || fail "plugin.cfg reads '${installed}'"
      ;;
    repository)
      grep -qF "[UPDATE-DRIVER] timeout waiting for staged" "${dir}/boot1.log" && pass "nothing was staged" || fail "the driver did not time out"
      if grep -qF ".update.json" "${dir}/server.log"; then fail "the installer asked for the manifest"; else pass "the installer never asked for the manifest"; fi
      [[ "${installed}" == "${OLD_VERSION}" && ! -e "${record}" ]] && pass "nothing changed" || fail "the folder or the record changed"
      ;;
    disable)
      grep -qF "[UPDATE-DRIVER] disabled the toolkit" "${dir}/boot1.log" && pass "the toolkit was disabled after staging" || fail "the toolkit was not disabled"
      [[ "${installed}" == "${OLD_VERSION}" && ! -e "${record}" ]] && pass "nothing was installed and the staged update is gone" || fail "the disable installed or kept the update"
      ;;
  esac
}

for leg in ${LEGS}; do
  echo "== ${leg}"
  run_leg "${leg}"
done

if [[ ${FAILED} -ne 0 ]]; then
  # Loud on failure, for CI, where the scratch folder is gone with the runner.
  for leg_dir in "${WORK}"/*/; do
    for log in boot1.log boot2.log server.log; do
      [[ -f "${leg_dir}${log}" ]] && { echo "--- ${leg_dir#"${WORK}"/}${log} (last 40 lines)"; tail -40 "${leg_dir}${log}"; }
    done
    [[ -f "${leg_dir}toolkit_user" ]] || continue
    leg_user="$(cat "${leg_dir}toolkit_user")"
    for file in update/install.log update/pending_update.json; do
      [[ -f "${leg_user}/${file}" ]] && { echo "--- ${leg_dir#"${WORK}"/}${file}"; cat "${leg_user}/${file}"; }
    done
  done
  echo "RESULT: FAIL — see the logs (UPDATE_FLOW_KEEP=1 keeps ${WORK})"
  exit 1
fi
echo "RESULT: PASS — every update flow leg passed"
