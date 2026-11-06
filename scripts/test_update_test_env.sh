#!/usr/bin/env bash
# scripts/test_update_test_env.sh
# Tests how ut_python_bin (scripts/lib/python_bin.sh, which update_test_env.sh
# sources) picks the Python the test harnesses run, against stand-in interpreters
# only, with no Python, no Godot and no network. Each case runs on a PATH of scratch folders alone, so no real
# interpreter, and no real Microsoft Store alias, can be found or run.
#
# A stand-in under a folder named WindowsApps plays the Store's app-execution alias:
# it writes a marker file when run and answers as a Python 3 would, so a resolver
# that runs it before checking where it lives picks it. Running the real alias with
# no Python installed downloads and installs one, so no case may ever run a
# WindowsApps stand-in.
#
# It also checks that ut_embed_trust (scripts/lib/update_test_env.sh) writes the
# embedded trust document as a const line under the rules of macOS's bash 3.2, run
# here as BASH_COMPAT=42; this part needs openssl.
#
# Usage: bash scripts/test_update_test_env.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/python_bin.sh
source "${REPO_ROOT}/scripts/lib/python_bin.sh"

# Through cd and pwd for a path with no drive colon: it goes on the PATH below.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-update-test-env.XXXXXX")" && pwd)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

check() {
  local label="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "  ok    ${label}"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${label}"
  fi
}

equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
is_empty() { [[ -z "$1" ]]; }
no_file() { [[ ! -e "$1" ]]; }
has_line() { grep -qE "$2" <<< "$1"; }
lacks_line() { ! grep -qE "$2" <<< "$1"; }

MARKER="${WORK}/alias-ran"

# fake <path> alias|good|old: an executable stand-in. An alias records that it ran;
# a good one answers the version check as Python 3, an old one as Python 2.
fake() {
  local path="$1" kind="$2"
  mkdir -p "$(dirname "${path}")"
  case "${kind}" in
    alias) printf '#!/bin/sh\n: > "%s"\nexit 0\n' "${MARKER}" > "${path}" ;;
    good) printf '#!/bin/sh\nexit 0\n' > "${path}" ;;
    old) printf '#!/bin/sh\nexit 1\n' > "${path}" ;;
  esac
  chmod +x "${path}"
}

ALIASES="${WORK}/AppData/Local/Microsoft/WindowsApps"
LOWER_ALIASES="${WORK}/lower/windowsapps"
GOOD="${WORK}/good"
GOOD_PYTHON_ONLY="${WORK}/good-python-only"
PINNED="${WORK}/pinned"
fake "${ALIASES}/python3" alias
fake "${ALIASES}/python" alias
fake "${LOWER_ALIASES}/python3" alias
fake "${GOOD}/python3" good
fake "${GOOD_PYTHON_ONLY}/python" good
fake "${PINNED}/python3" good
fake "${PINNED}/python2" old

# pick <path-list> [UT_PYTHON value]: runs ut_python_bin in a subshell on that PATH
# alone; sets OUT, ERR and STATUS.
pick() {
  local search="$1"
  rm -f "${MARKER}"
  STATUS=0
  if [[ $# -ge 2 ]]; then
    OUT="$(PATH="${search}"; export UT_PYTHON="$2"; ut_python_bin 2> "${WORK}/err")" || STATUS=$?
  else
    OUT="$(PATH="${search}"; unset UT_PYTHON; ut_python_bin 2> "${WORK}/err")" || STATUS=$?
  fi
  ERR="$(cat "${WORK}/err")"
}

echo "ut_python_bin"

pick "${ALIASES}:${GOOD}"
check "skips a WindowsApps python3 without running it" no_file "${MARKER}"
check "picks the first python3 outside WindowsApps" equals "${OUT}" "${GOOD}/python3"

pick "${LOWER_ALIASES}:${GOOD}"
check "a lower-case windowsapps folder is skipped unrun too" no_file "${MARKER}"
check "and the python3 after it is picked" equals "${OUT}" "${GOOD}/python3"

pick "${ALIASES}:${GOOD_PYTHON_ONLY}"
check "skips both WindowsApps names without running them" no_file "${MARKER}"
check "falls through to a python outside WindowsApps" equals "${OUT}" "${GOOD_PYTHON_ONLY}/python"

pick "${ALIASES}:${GOOD}" "${PINNED}/python3"
check "UT_PYTHON wins over the PATH" equals "${OUT}" "${PINNED}/python3"
check "and nothing in WindowsApps runs" no_file "${MARKER}"

pick "${PINNED}:${ALIASES}" python3
check "UT_PYTHON may name a command on the PATH" equals "${OUT}" "${PINNED}/python3"

pick "${ALIASES}:${GOOD}" "${PINNED}/python2"
check "a UT_PYTHON that is not Python 3 fails" equals "${STATUS}" 1
check "without falling back to the PATH" is_empty "${OUT}"
check "naming UT_PYTHON" contains "${ERR}" "UT_PYTHON"
check "and running nothing in WindowsApps" no_file "${MARKER}"

pick "${GOOD}" "${WORK}/missing/python3"
check "a UT_PYTHON that does not exist fails" equals "${STATUS}" 1
check "without falling back to the PATH" is_empty "${OUT}"

pick "${GOOD}" "${ALIASES}/python3"
check "a UT_PYTHON under WindowsApps is refused" equals "${STATUS}" 1
check "unrun" no_file "${MARKER}"

pick "${ALIASES}"
check "with only WindowsApps on the PATH it fails" equals "${STATUS}" 1
check "unrun" no_file "${MARKER}"
check "naming UT_PYTHON" contains "${ERR}" "UT_PYTHON"
check "and why WindowsApps is skipped" contains "${ERR}" "WindowsApps"

echo "ut_embed_trust"

# Bash before 4.3, macOS's /bin/bash among them, keeps the quotes of a quoted ${x/p/"r"}
# replacement; BASH_COMPAT=42 gives a newer bash the same rule, which the child checks
# on itself first so the case cannot pass on a bash that ignores it.
EMBED="${WORK}/embed"
mkdir -p "${EMBED}/addon/self_update"
cp "${REPO_ROOT}/addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd" "${EMBED}/addon/self_update/"
STATUS=0
OUT="$(BASH_COMPAT=42 bash -c '
  x=a
  [[ "${x/a/"b"}" == "\"b\"" ]] && echo "old quote rule"
  source "$1" && ut_make_key "$2/key.pem" && ut_embed_trust "$2/addon" "$2/key.pem" "$2/key.pub.pem"
' _ "${REPO_ROOT}/scripts/lib/update_test_env.sh" "${EMBED}" 2> "${WORK}/err")" || STATUS=$?
EMBEDDED="$(cat "${EMBED}/addon/self_update/embedded_trust_document.gd")"
check "the child bash keeps the replacement's quotes, as bash 3.2 does" equals "${OUT}" "old quote rule"
check "and the document is embedded" equals "${STATUS}" 0
check "as a const line" has_line "${EMBEDDED}" "^const DOCUMENT := '\{"
check "with no quotes around it" lacks_line "${EMBEDDED}" '^"const DOCUMENT'

echo
echo "${PASSED} passed, ${FAILED} failed"
[[ "${FAILED}" -eq 0 ]]
