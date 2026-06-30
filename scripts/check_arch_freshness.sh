#!/usr/bin/env bash
#
# Advisory provenance-freshness check for the repo's descriptive-of-code docs
# (NON-BLOCKING by design).
#
# Scans each per-section provenance comment in every doc it checks:
#   <!-- data-depicts="<files>" data-verified="<short-sha>" -->
# and reports any section whose depicted source files changed since its
# data-verified SHA (i.e. `git log <sha>..HEAD -- <files>` is non-empty).
#
# By default it checks the two docs that describe the code and drift the same way:
#   - docs/architecture/README.md   (the architecture diagrams)
#   - docs/dev/contract.md          (the toolkit<->server contract surface)
# Both are descriptive-of-code, so both go stale when the source moves. (Normative
# docs such as code-standards.md are NOT checked — they track decisions, not files,
# and have nothing to data-depict.) Pass explicit path(s) to scan only those.
#
# A stale flag means: re-read the section against the code, fix it if it drifted,
# and bump its data-verified SHA (the bump is an attestation that you re-checked).
# It over-flags by design — a false re-check costs a glance; a missed drift ships a
# lying doc. Run it at doc milestones (release prep, future review passes), NOT
# as a blocking CI gate (a hot-file gate degrades the attestation into a rubber stamp).
#
# Usage:  bash scripts/check_arch_freshness.sh [doc ...]
# See:    docs/architecture/README.md  →  "Maintaining this document"
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO_ROOT" || exit 0

# No args → scan the standard descriptive-of-code set. Explicit path(s) override
# it, scanning only those (handy for checking one doc in isolation).
if [[ "$#" -gt 0 ]]; then
	DOCS=("$@")
else
	DOCS=("docs/architecture/README.md" "docs/dev/contract.md")
fi

# Summary noun per doc: the architecture doc renders diagrams; other docs (the
# contract) are organised into sections.
unit_for() {
	case "$1" in
	*docs/architecture/*) printf 'diagram' ;;
	*) printf 'section' ;;
	esac
}

# Run the per-section provenance scan over a single doc. Self-contained: prints a
# header, one line per stale/unknown section, and a summary; never blocks.
scan_doc() {
	local doc="$1"
	local unit
	unit="$(unit_for "$doc")"

	if [[ ! -f "$doc" ]]; then
		echo "check:arch — no doc at '$doc' (nothing to check)"
		echo ""
		return 0
	fi

	echo "check:arch — scanning provenance comments in $doc"
	echo ""

	local total=0
	local doc_stale=0

	while IFS= read -r line; do
		local depicts verified
		depicts="$(printf '%s' "$line" | sed -n 's/.*data-depicts="\([^"]*\)".*/\1/p')"
		verified="$(printf '%s' "$line" | sed -n 's/.*data-verified="\([^"]*\)".*/\1/p')"
		[[ -z "$depicts" || -z "$verified" ]] && continue
		total=$((total + 1))

		if ! git cat-file -e "${verified}^{commit}" 2>/dev/null; then
			echo "  ?  unknown data-verified SHA '$verified'  (depicts: $depicts)"
			doc_stale=$((doc_stale + 1))
			continue
		fi

		# Word-splitting $depicts into multiple pathspecs is intentional (no quotes).
		local changed
		changed="$(git log --oneline "${verified}..HEAD" -- $depicts 2>/dev/null)"
		if [[ -n "$changed" ]]; then
			local n
			n="$(printf '%s\n' "$changed" | grep -c .)"
			echo "  ⚠  STALE since $verified ($n commit(s) touched depicted files):"
			echo "       $depicts"
			doc_stale=$((doc_stale + 1))
		fi
	done < <(grep -o '<!--[[:space:]]*data-depicts="[^>]*-->' "$doc")

	echo ""
	if [[ "$total" -eq 0 ]]; then
		echo "check:arch — no provenance comments found (is the doc using the data-depicts convention?)"
	elif [[ "$doc_stale" -eq 0 ]]; then
		echo "check:arch — all $total ${unit}(s) fresh ✓"
	else
		echo "check:arch — $doc_stale of $total ${unit}(s) may be stale (advisory; re-verify + bump data-verified)"
	fi
	echo ""
}

for doc in "${DOCS[@]}"; do
	scan_doc "$doc"
done

# Advisory: never block.
exit 0
