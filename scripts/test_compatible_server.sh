#!/usr/bin/env bash
# scripts/test_compatible_server.sh
# Tests scripts/lib/compatible_server.sh and release.sh's server-pin flags, with
# no network and no change to the repo:
#   - cs_current and cs_template_token read the real files, and they agree;
#   - cs_rewrite sets both on temp copies, keeping LF and CRLF line endings;
#   - cs_probe_npm, against a stubbed npm, accepts a published version and
#     refuses an unpublished one and an unreachable registry;
#   - release.sh refuses neither pin flag, both, and a malformed version while it
#     is still parsing its arguments, before any git command.
#
# Usage: bash scripts/test_compatible_server.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compatible_server.sh
source "${REPO_ROOT}/scripts/lib/compatible_server.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-compatible-server.XXXXXX")"
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

# Copies the two pinned files into <dir> at their repo paths; with "crlf", every
# line of the copies ends in CRLF, as on a Windows checkout.
make_copy() {
  local dir="$1" eol="${2:-lf}" path
  for path in "${CS_CONSTANT_FILE}" "${CS_TEMPLATE_FILE}"; do
    mkdir -p "${dir}/$(dirname "${path}")"
    tr -d '\r' < "${REPO_ROOT}/${path}" > "${dir}/${path}"
    if [[ "${eol}" == "crlf" ]]; then
      sed 's/$/\r/' "${dir}/${path}" > "${dir}/${path}.crlf" && mv "${dir}/${path}.crlf" "${dir}/${path}"
    fi
  done
}

is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# -U keeps Git Bash's grep from dropping each line's CR before matching.
has_no_cr() { ! grep -qU $'\r' "$1"; }
# Every line ends in CR: no line lacks one.
all_lines_crlf() { ! grep -qvU $'\r$' "$1"; }
same_line_count() { [[ "$(wc -l < "$1")" == "$(wc -l < "$2")" ]]; }
equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }

echo "── reading the pin ──"
CURRENT="$(cs_current "${REPO_ROOT}")"
TOKEN="$(cs_template_token "${REPO_ROOT}")"
check "cs_current reads a semver ('${CURRENT}')" is_semver "${CURRENT}"
check "the template pins the same version ('${TOKEN}')" equals "${TOKEN}" "${CURRENT}"

echo "── rewriting both files ──"
for eol in lf crlf; do
  copy="${WORK}/${eol}"
  make_copy "${copy}" "${eol}"
  cs_rewrite "${copy}" "9.8.7" >/dev/null
  check "${eol}: cs_current after rewrite" equals "$(cs_current "${copy}")" "9.8.7"
  check "${eol}: template token after rewrite" equals "$(cs_template_token "${copy}")" "9.8.7"
  for path in "${CS_CONSTANT_FILE}" "${CS_TEMPLATE_FILE}"; do
    check "${eol}: $(basename "${path}") keeps its line count" same_line_count "${copy}/${path}" "${REPO_ROOT}/${path}"
    if [[ "${eol}" == "lf" ]]; then
      check "lf: $(basename "${path}") stays LF" has_no_cr "${copy}/${path}"
    else
      check "crlf: $(basename "${path}") stays CRLF" all_lines_crlf "${copy}/${path}"
    fi
  done
done

echo "── probing npm (stubbed) ──"
# A function named npm shadows the real one for cs_probe_npm. NPM_STUB picks the
# registry's answer; 1.2.3 is the one published version.
NPM_STUB="published"
npm() {
  case "${NPM_STUB}" in
    down)
      echo "npm error code ENOTFOUND" >&2
      return 1
      ;;
    empty)
      # An older npm answers an unknown version with nothing at all.
      [[ "$2" == *"@"*"@"* ]] && return 0
      printf '"1.2.3"\r\n'
      ;;
    *)
      if [[ "$2" == *"@1.2.3" || "$2" != *"@"*"@"* ]]; then
        printf '"1.2.3"\r\n'
      else
        printf '{"error":{"code":"E404"}}\n'
        return 1
      fi
      ;;
  esac
}
NPM_STUB="published"
check "a published version passes" cs_probe_npm "1.2.3"
REASON="$(cs_probe_npm "9.9.9")" && STATUS=0 || STATUS=$?
check "an unpublished version fails" equals "${STATUS}" "1"
check "its reason says to publish first" contains "${REASON}" "is not on npm — publish the server first"
NPM_STUB="empty"
REASON="$(cs_probe_npm "9.9.9")" && STATUS=0 || STATUS=$?
check "an empty npm answer fails as unpublished" contains "${REASON}" "is not on npm"
NPM_STUB="down"
REASON="$(cs_probe_npm "1.2.3")" && STATUS=0 || STATUS=$?
check "an unreachable registry fails" equals "${STATUS}" "1"
check "its reason names the registry" contains "${REASON}" "cannot reach the npm registry"
unset -f npm

echo "── release.sh pin flags (parsing only) ──"
# An exported git function reports any git call the parse makes before refusing.
git() { echo "GIT CALLED: $*" >&2; return 99; }
export -f git
run_release() {
  RELEASE_OUT="$(bash "${REPO_ROOT}/scripts/release.sh" "$@" 2>&1)" && RELEASE_STATUS=0 || RELEASE_STATUS=$?
}
run_release 1.1.0 --dry-run
check "neither flag: refused" equals "${RELEASE_STATUS}" "1"
check "neither flag: names --compatible-server" contains "${RELEASE_OUT}" "--compatible-server <X.Y.Z>"
check "neither flag: names --keep-compatible-server" contains "${RELEASE_OUT}" "--keep-compatible-server"
check "neither flag: no git call" equals "$(contains "${RELEASE_OUT}" "GIT CALLED" && echo yes || echo no)" "no"
run_release 1.1.0 --dry-run --compatible-server 1.0.4 --keep-compatible-server
check "both flags: refused" equals "${RELEASE_STATUS}" "1"
check "both flags: says not both" contains "${RELEASE_OUT}" "not both"
check "both flags: no git call" equals "$(contains "${RELEASE_OUT}" "GIT CALLED" && echo yes || echo no)" "no"
run_release 1.1.0 --dry-run --compatible-server 1.0
check "malformed pin: refused" equals "${RELEASE_STATUS}" "1"
check "malformed pin: says why" contains "${RELEASE_OUT}" "not a well-formed semver"
check "malformed pin: no git call" equals "$(contains "${RELEASE_OUT}" "GIT CALLED" && echo yes || echo no)" "no"
unset -f git

echo ""
if [[ ${FAILED} -eq 0 ]]; then
  echo "PASS: ${PASSED} checks"
  exit 0
fi
echo "FAIL: ${FAILED} of $((PASSED + FAILED)) checks failed"
exit 1
