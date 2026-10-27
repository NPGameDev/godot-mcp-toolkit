# shellcheck shell=bash
#
# scripts/lib/update_test_env.sh: the scratch projects and the stand-in for GitHub
# that the self-update's end-to-end tests share: scripts/test_framework/update_flow.sh
# (headless) and scripts/test_framework/update_gui.sh (an editor with a window).
#
# Sourced, never run, after scripts/lib/release_files.sh. Runs under bash on Linux,
# macOS and Windows (Git Bash).
#
#   ut_os                               print linux, macos or windows
#   ut_timeout_bin                      print this OS's GNU timeout command
#   ut_python_bin                       print a command that runs Python 3, or fail
#   ut_set_read_only <file> true|false  Windows only: set or clear <file>'s
#                                       read-only attribute, so a write to it fails
#   ut_previous_version <version>       print the version one step older within the
#                                       same major, or nothing for a major release,
#                                       which the toolkit only ever links to
#   ut_make_key <name.pem>              write an RSA key and its public half,
#                                       <name>.pub.pem
#   ut_install_old_toolkit <repo-root> <addon-dir> <version> <public-pem> <own-file>
#                                       copy this tree's toolkit to <addon-dir> at
#                                       <version>, trusting <public-pem>, holding a
#                                       file named <own-file> no release has, with its
#                                       release file list
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

# The Windows runner names Python 3 `python`, and a `python3` there can be the
# Microsoft Store's stub, which runs nothing.
ut_python_bin() {
  local candidate
  for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1 \
      && "${candidate}" -c 'import sys; sys.exit(sys.version_info[0] != 3)' 2>/dev/null; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

# NTFS ignores chmod. The read-only attribute makes a write to the file fail while it
# still reads, so an apply backs it up and then fails to write it.
ut_set_read_only() {
  powershell -NoProfile -Command "Set-ItemProperty -LiteralPath '$(cygpath -w "$1")' -Name IsReadOnly -Value \$$2"
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

ut_install_old_toolkit() {
  local repo_root="$1" addon="$2" version="$3" public_pem="$4" own_file="$5"
  mkdir -p "$(dirname "${addon}")"
  cp -r "${repo_root}/addons/godot_mcp_toolkit" "${addon}"
  sed -i.bak -E "s/^version=\"[^\"]+\"/version=\"${version}\"/" "${addon}/plugin.cfg" && rm -f "${addon}/plugin.cfg.bak"
  local key_entry
  key_entry="$(bash "${repo_root}/scripts/sign-release.sh" --key-entry "${public_pem}")"
  "$(ut_python_bin)" - "${addon}/update/trusted_release_keys.gd" "${key_entry}" <<'PY'
import sys
path, entry = sys.argv[1], sys.argv[2]
text = open(path).read()
assert "const PUBLIC_KEYS := []" in text
open(path, "w").write(text.replace("const PUBLIC_KEYS := []", "const PUBLIC_KEYS := [\n" + entry + "\n]"))
PY
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
