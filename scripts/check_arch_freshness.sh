#!/usr/bin/env bash
#
# Advisory architecture-doc freshness check (NON-BLOCKING by design).
#
# Scans each per-diagram provenance comment in the architecture doc:
#   <!-- data-depicts="<files>" data-verified="<short-sha>" -->
# and reports any diagram whose depicted source files changed since its
# data-verified SHA (i.e. `git log <sha>..HEAD -- <files>` is non-empty).
#
# A stale flag means: re-read the diagram against the code, fix it if it drifted,
# and bump its data-verified SHA (the bump is an attestation that you re-checked).
# It over-flags by design — a false re-check costs a glance; a missed drift ships a
# lying diagram. Run it at doc milestones (release prep, future review passes), NOT
# as a blocking CI gate (a hot-file gate degrades the attestation into a rubber stamp).
#
# Usage:  bash scripts/check_arch_freshness.sh [path/to/architecture/README.md]
# See:    docs/architecture/README.md  →  "Maintaining this document"
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 0

DOC="${1:-docs/architecture/README.md}"

if [[ ! -f "$DOC" ]]; then
	echo "check:arch — no architecture doc at '$DOC' (nothing to check)"
	exit 0
fi

echo "check:arch — scanning provenance comments in $DOC"
echo ""

total=0
stale=0

while IFS= read -r line; do
	depicts="$(printf '%s' "$line" | sed -n 's/.*data-depicts="\([^"]*\)".*/\1/p')"
	verified="$(printf '%s' "$line" | sed -n 's/.*data-verified="\([^"]*\)".*/\1/p')"
	[[ -z "$depicts" || -z "$verified" ]] && continue
	total=$((total + 1))

	if ! git cat-file -e "${verified}^{commit}" 2>/dev/null; then
		echo "  ?  unknown data-verified SHA '$verified'  (depicts: $depicts)"
		stale=$((stale + 1))
		continue
	fi

	# Word-splitting $depicts into multiple pathspecs is intentional (no quotes).
	changed="$(git log --oneline "${verified}..HEAD" -- $depicts 2>/dev/null)"
	if [[ -n "$changed" ]]; then
		n="$(printf '%s\n' "$changed" | grep -c .)"
		echo "  ⚠  STALE since $verified ($n commit(s) touched depicted files):"
		echo "       $depicts"
		stale=$((stale + 1))
	fi
done < <(grep -o '<!--[[:space:]]*data-depicts="[^>]*-->' "$DOC")

echo ""
if [[ "$total" -eq 0 ]]; then
	echo "check:arch — no provenance comments found (is the doc using the data-depicts convention?)"
elif [[ "$stale" -eq 0 ]]; then
	echo "check:arch — all $total diagram(s) fresh ✓"
else
	echo "check:arch — $stale of $total diagram(s) may be stale (advisory; re-verify + bump data-verified)"
fi

# Advisory: never block.
exit 0
