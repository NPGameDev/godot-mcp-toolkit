# shellcheck shell=bash
#
# scripts/lib/compatible_server.sh: helpers for the server version the toolkit
# pins (COMPATIBLE_SERVER_VERSION). "Write .mcp.json" pins the server to it, and
# .mcp.json.template carries the same version for a hand copy, so the two must
# always agree.
#
# Sourced, never run: scripts/release.sh uses it to state each release's pin,
# and scripts/test_compatible_server.sh tests it. Every function takes the repo
# root (or a copy of it) as its first argument, so tests can run on temp copies.
#
#   cs_current <root>            print the constant's version
#   cs_template_token <root>     print the version in the template's package spec
#   cs_probe_npm <version>       succeed when <version> is published on npm; on
#                                failure, print the reason and return 1
#   cs_rewrite <root> <version>  set both to <version>, keeping each file's EOL
#
# Windows checkouts may be CRLF: every read strips CR, and the rewrite edits
# only the one line it changes.

CS_PACKAGE="@npgamedev/godot-mcp-server"
CS_CONSTANT_FILE="addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd"
CS_TEMPLATE_FILE="addons/godot_mcp_toolkit/.mcp.json.template"

cs_current() {
  local root="$1"
  grep -E '^const COMPATIBLE_SERVER_VERSION := "' "${root}/${CS_CONSTANT_FILE}" \
    | head -1 \
    | tr -d '\r' \
    | sed -E 's/^const COMPATIBLE_SERVER_VERSION := "([^"]*)".*/\1/'
}

cs_template_token() {
  local root="$1"
  # Greedy up to the last "@", so the scope's own "@" is skipped.
  grep -oE "\"${CS_PACKAGE}@[^\"]*\"" "${root}/${CS_TEMPLATE_FILE}" \
    | head -1 \
    | sed -E 's/^".*@([^@"]*)"$/\1/'
}

# The registry is checked first: a failed lookup of the version alone cannot tell
# "not published" from "registry unreachable". npm prints the version as a JSON
# string, through a .cmd shim on Windows, so quotes and CR are stripped.
cs_probe_npm() {
  local version="$1" answered
  if ! npm view "${CS_PACKAGE}" version --json >/dev/null 2>&1; then
    echo "cannot reach the npm registry (npm view ${CS_PACKAGE} failed)"
    return 1
  fi
  answered="$(npm view "${CS_PACKAGE}@${version}" version --json 2>/dev/null | tr -d '\r"[:space:]')" || answered=""
  if [[ "${answered}" != "${version}" ]]; then
    echo "server ${version} is not on npm — publish the server first"
    return 1
  fi
}

cs_rewrite() {
  local root="$1" version="$2"
  local constant="${root}/${CS_CONSTANT_FILE}" template="${root}/${CS_TEMPLATE_FILE}"
  # BINMODE=3 stops Git Bash's awk from dropping the CR of a CRLF line (other awks
  # ignore it), so each file keeps its line endings.
  awk -v BINMODE=3 -v ver="${version}" '
    index($0, "const COMPATIBLE_SERVER_VERSION := \"") == 1 { sub(/"[^"]*"/, "\"" ver "\"") }
    { print }
  ' "${constant}" > "${constant}.tmp.$$" && mv "${constant}.tmp.$$" "${constant}"
  # Literal index() matches, not a dynamic regex: the package name carries "@"
  # and "/", and only the version after it changes.
  awk -v BINMODE=3 -v pkg="${CS_PACKAGE}" -v ver="${version}" '
    {
      start = index($0, "\"" pkg "@")
      if (start > 0) {
        head = substr($0, 1, start + length(pkg) + 1)
        rest = substr($0, start + length(pkg) + 2)
        $0 = head ver substr(rest, index(rest, "\""))
      }
      print
    }
  ' "${template}" > "${template}.tmp.$$" && mv "${template}.tmp.$$" "${template}"
  if [[ "$(cs_current "${root}")" != "${version}" || "$(cs_template_token "${root}")" != "${version}" ]]; then
    echo "could not set the compatible server version to ${version} in ${CS_CONSTANT_FILE} and ${CS_TEMPLATE_FILE}"
    return 1
  fi
}
