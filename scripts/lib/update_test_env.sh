# shellcheck shell=bash
#
# scripts/lib/update_test_env.sh: the scratch projects and the stand-in for GitHub
# that the self-update's end-to-end tests share: scripts/test_framework/update_flow.sh
# (headless) and scripts/test_framework/update_gui.sh (an editor with a window).
#
# Sourced, never run, after scripts/lib/release_files.sh. Runs under bash on Linux,
# macOS and Windows (Git Bash). Sources scripts/lib/python_bin.sh, so ut_python_bin
# is defined too.
#
#   ut_os                               print linux, macos or windows
#   ut_timeout_bin                      print this OS's GNU timeout command
#   ut_previous_version <version>       print the version one step older within the
#                                       same major, or nothing for a major release,
#                                       which the toolkit only ever links to
#   ut_make_key <name.pem>              write an RSA key and its public half,
#                                       <name>.pub.pem
#   ut_embed_trust <addon-dir> <private-pem> <public-pem>
#                                       make the toolkit at <addon-dir> trust <public-pem>:
#                                       a first trust document with it as the root and
#                                       the release key, signed by <private-pem>, becomes
#                                       the document the toolkit embeds
#   ut_install_old_toolkit <repo-root> <addon-dir> <version> <private-pem> <public-pem> <own-file>
#                                       copy this tree's toolkit to <addon-dir> at
#                                       <version>, trusting <public-pem> (ut_embed_trust),
#                                       holding a file named <own-file> no release has,
#                                       with its release file list
#   ut_warm <godot> <project> <log>     boot a headless editor on <project>, up to three
#                                       times, until it has written the global class
#                                       cache, which Godot 4.2 needs before the plugin
#                                       parses
#   ut_user_dir <godot> <project>       print the project's user:// folder
#   ut_mark_setup_seen <user-dir>       record every setup step as seen, so no setup
#                                       wizard opens and the consent gate is open
#   ut_stage_release <server-dir> <tag> <version> <zip> <manifest> <signing-pem>
#                                       lay out, under <server-dir>, the replies the
#                                       update check (latest release <tag>, no Asset
#                                       Store listing) and the installer (<version>'s
#                                       zip, manifest and signature) ask for; serve it
#                                       through GODOT_MCP_UPDATE_CHECK_HOST
#   ut_recommend_server <addon-dir> <version>
#                                       make the toolkit at <addon-dir> recommend MCP
#                                       server <version>, with its release file list
#   ut_write_mcp_json <project> <version>
#                                       write a .mcp.json whose toolkit entry runs server
#                                       <version>, with a user's env key
#                                       (GODOT_MCP_TEST_KEEP) and another server
#                                       (other-server) beside it
#   ut_record_last_write <project> <version>
#                                       record server <version> as this machine's last
#                                       write into the project's .mcp.json

# shellcheck source=python_bin.sh
source "$(dirname "${BASH_SOURCE[0]}")/python_bin.sh"
# shellcheck source=compatible_server.sh
source "$(dirname "${BASH_SOURCE[0]}")/compatible_server.sh"

ut_os() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    Darwin) echo macos ;;
    *) echo linux ;;
  esac
}

# On Windows a bare `timeout` can resolve to System32's timeout.exe, which runs no
# command; Git Bash ships GNU coreutils' at /usr/bin/timeout. macOS has no timeout,
# and the GitHub runner carries coreutils' gtimeout.
ut_timeout_bin() {
  case "$(ut_os)" in
    windows) echo /usr/bin/timeout ;;
    macos) echo gtimeout ;;
    *) echo timeout ;;
  esac
}

ut_previous_version() {
  local major minor patch
  IFS=. read -r major minor patch <<< "$1"
  if (( patch > 0 )); then
    echo "${major}.${minor}.$(( patch - 1 ))"
  elif (( minor > 0 )); then
    echo "${major}.$(( minor - 1 )).0"
  fi
}

ut_make_key() {
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null
  openssl pkey -in "$1" -pubout -out "${1%.pem}.pub.pem"
}

# The embedded document is read without its signatures, but a signed one is what a
# release ships, so the toolkit under test reads the same shape. trust-document.sh's
# sign reads a passphrase line from a pipe even for a plain key.
ut_embed_trust() {
  local addon="$1" private_pem="$2" public_pem="$3"
  local tool target="${addon}/self_update/embedded_trust_document.gd" empty='const DOCUMENT := ""'
  tool="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/trust-document.sh"
  local text
  text="$(cat "${target}")" || return 1
  if [[ "${text}" != *"${empty}"* ]]; then
    echo "ERROR: ${target} does not hold an empty document" >&2
    return 1
  fi
  local folder
  folder="$(mktemp -d "$(dirname "${private_pem}")/trust.XXXXXX")" || return 1
  bash "${tool}" build --first --add-root "${public_pem}" --add-release "${public_pem}" --out "${folder}" > /dev/null \
    && echo unused | bash "${tool}" sign "${folder}/trust-1.json" "${private_pem}" > /dev/null \
    || { echo "ERROR: could not build and sign a trust document" >&2; return 1; }
  local document
  document="$(cat "${folder}/trust-1.json")"
  rm -f "${folder}/trust-1.json"
  rmdir "${folder}"
  # Split around the placeholder: macOS's bash 3.2 keeps the quotes of a quoted ${x/p/"r"} replacement.
  local before="${text%%"${empty}"*}" after="${text#*"${empty}"}"
  printf '%s%s%s\n' "${before}" "const DOCUMENT := '${document}'" "${after}" > "${target}"
}

ut_install_old_toolkit() {
  local repo_root="$1" addon="$2" version="$3" private_pem="$4" public_pem="$5" own_file="$6"
  mkdir -p "$(dirname "${addon}")"
  cp -r "${repo_root}/addons/godot_mcp_toolkit" "${addon}"
  sed -i.bak -E "s/^version=\"[^\"]+\"/version=\"${version}\"/" "${addon}/plugin.cfg" && rm -f "${addon}/plugin.cfg.bak"
  ut_embed_trust "${addon}" "${private_pem}" "${public_pem}" || return 1
  echo "a file only the installed version has" > "${addon}/${own_file}"
  rf_write_list "${addon}"
}

# Each boot quits on its own after a frame budget, and the cache file decides whether
# another boot is needed: a slow disk can outlast one budget. An editor killed while
# it works instead left a project whose windowed editors crashed on their way out
# (Godot 4.7.2).
ut_warm() {
  local godot="$1" project="$2" log="$3"
  for _ in 1 2 3; do
    "${godot}" --headless --editor --path "${project}" --quit-after 3000 >> "${log}" 2>&1
    [[ -f "${project}/.godot/global_script_class_cache.cfg" ]] && return 0
  done
  return 1
}

ut_user_dir() {
  local godot="$1" project="$2"
  local probe="${project}/../user_dir_probe.gd"
  printf 'extends SceneTree\n\nfunc _init() -> void:\n\tprint("USER_DIR=", OS.get_user_data_dir())\n\tquit()\n' > "${probe}"
  "${godot}" --headless --path "${project}" --script "${probe}" 2>/dev/null | sed -n 's/^USER_DIR=//p' | tail -1
}

ut_mark_setup_seen() {
  mkdir -p "$1/addons/godot_mcp_toolkit"
  printf '{"format": 1, "seen": ["welcome", "mcp_json", "optional_steps", "updates", "update_install", "dock"]}' \
    > "$1/addons/godot_mcp_toolkit/mcp_onboarding_shown_v001"
}

ut_stage_release() {
  local server="$1" tag="$2" version="$3" zip="$4" manifest="$5" signing_pem="$6"
  local download="${server}/NPGameDev/godot-mcp-toolkit/releases/download/v${version}"
  mkdir -p "${download}" "${server}/repos/NPGameDev/godot-mcp-toolkit/releases" \
    "${server}/api/v1/releases/npgamedev/godot-mcp-toolkit"
  printf '{"tag_name": "v%s"}' "${tag}" > "${server}/repos/NPGameDev/godot-mcp-toolkit/releases/latest"
  printf '[]' > "${server}/api/v1/releases/npgamedev/godot-mcp-toolkit/index.html"
  cp "${zip}" "${manifest}" "${download}/"
  openssl dgst -sha256 -sign "${signing_pem}" -out "${download}/$(basename "${manifest}").sig" "${manifest}"
}

ut_recommend_server() {
  local addon="$1" version="$2"
  # The addon sits at <project>/addons/<id>, the root cs_rewrite resolves its files from.
  cs_rewrite "$(dirname "$(dirname "${addon}")")" "${version}" || return 1
  rf_write_list "${addon}"
}

ut_write_mcp_json() {
  local project="$1" version="$2"
  printf '{\n\t"mcpServers": {\n\t\t"godot-mcp-toolkit": {\n\t\t\t"command": "npx",\n\t\t\t"args": ["-y", "@npgamedev/godot-mcp-server@%s"],\n\t\t\t"env": {"GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_TEST_KEEP": "1", "npm_config_prefer_offline": "true"}\n\t\t},\n\t\t"other-server": {"command": "other"}\n\t}\n}\n' \
    "${version}" > "${project}/.mcp.json"
}

ut_record_last_write() {
  local project="$1" version="$2"
  mkdir -p "${project}/.godot/editor"
  printf '\n[mcp_toolkit]\n\nlast_written_server_spec="npx:%s"\n' "${version}" >> "${project}/.godot/editor/project_metadata.cfg"
}
