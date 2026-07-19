#!/usr/bin/env bash
# scripts/check_docs_counts.sh
# Docs-drift gate: user-facing docs may only carry tool-surface numbers that
# match the pinned expectations below, and no retired vocabulary.
#
# ── PINNED EXPECTATIONS ──────────────────────────────────────────────────────
# The server repo's src/registration/catalogue.ts is the SSOT for these counts
# (printed by `godot-mcp-server --tools-count`, asserted by the server's
# structural test). When --tools-count changes, bump the constants here AND
# the README headline in the same change.
# ─────────────────────────────────────────────────────────────────────────────
#
# Checks:
#   1. The root README headline carries the pinned numbers.
#   2. No retired vocabulary (internal host labels, removed profile system)
#      appears in any user-facing doc.
#
# Usage: bash scripts/check_docs_counts.sh   (repo root; grep-only, no Godot)
# Exit 0 = clean, 1 = drift found, 2 = setup error

set -u

EXPECTED_TOOLS="112 tools"
EXPECTED_GROUPS="28 on-demand groups"
EXPECTED_OPERATIONS="150+ operations"

# User-facing surfaces. docs/dev/** is deliberately excluded: the glossary
# defines the retired vocabulary in order to ban it.
USER_FACING=(
  "README.md"
  "addons/godot_mcp_toolkit/README.md"
  "docs/README.md"
  "docs/troubleshooting.md"
)
USER_FACING_DIRS=(
  "addons/godot_mcp_toolkit/docs"
)

RETIRED_PATTERN='Mode A|Mode B|Power User|GODOT_MCP_PROFILE|GODOT_MCP_CUSTOM_TOOLS|enable_tool_group'

if [ ! -f "README.md" ] || [ ! -f "project.godot" ]; then
  echo "ERROR: run from the toolkit repo root" >&2
  exit 2
fi

fail=0

echo "check:docs-counts — README headline vs pinned expectations"
for expected in "$EXPECTED_TOOLS" "$EXPECTED_GROUPS" "$EXPECTED_OPERATIONS"; do
  if grep -q -F "$expected" README.md; then
    echo "  ok: \"$expected\" present"
  else
    echo "  FAIL: README.md does not contain \"$expected\" (headline drifted, or the surface changed — re-check --tools-count and update both)" >&2
    fail=1
  fi
done

echo "check:docs-counts — retired vocabulary in user-facing docs"
hits=$(grep -rnE "$RETIRED_PATTERN" "${USER_FACING[@]}" "${USER_FACING_DIRS[@]}" 2>/dev/null)
if [ -n "$hits" ]; then
  echo "  FAIL: retired vocabulary found:" >&2
  echo "$hits" | sed 's/^/    /' >&2
  fail=1
else
  echo "  ok: no retired vocabulary"
fi

if [ "$fail" -ne 0 ]; then
  echo "check:docs-counts — FAIL (docs drift; see above)" >&2
  exit 1
fi
echo "check:docs-counts — PASS"
