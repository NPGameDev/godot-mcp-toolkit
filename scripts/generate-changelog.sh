#!/usr/bin/env bash
# Generate CHANGELOG.md from conventional commit history.
# Usage:
#   ./scripts/generate-changelog.sh              # full history
#   ./scripts/generate-changelog.sh --since=v1.0.0  # incremental from tag

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SINCE_ARG=""
if [[ "${1:-}" == --since=* ]]; then
  SINCE_ARG="${1#--since=}"
fi

if [[ -n "$SINCE_ARG" ]]; then
  LOG_RANGE="${SINCE_ARG}..HEAD"
else
  LOG_RANGE=""
fi

echo "# Changelog"
echo ""
echo "All notable changes to the Godot MCP Toolkit are documented in this file."
echo ""
echo "This changelog is auto-generated from [Conventional Commits](https://www.conventionalcommits.org/)."
echo ""

declare -a FEATS=() FIXES=() REFACTORS=() DOCS=() CHORES=() OTHERS=()

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  hash="${line%% *}"
  msg="${line#* }"
  short="${hash:0:7}"

  case "$msg" in
    feat*)    FEATS+=("- ${msg} (\`${short}\`)") ;;
    fix*)     FIXES+=("- ${msg} (\`${short}\`)") ;;
    refactor*) REFACTORS+=("- ${msg} (\`${short}\`)") ;;
    docs*)    DOCS+=("- ${msg} (\`${short}\`)") ;;
    chore*|build*|test*) CHORES+=("- ${msg} (\`${short}\`)") ;;
    *)        OTHERS+=("- ${msg} (\`${short}\`)") ;;
  esac
done < <(git log $LOG_RANGE --format="%H %s" --reverse)

if [[ ${#FEATS[@]} -gt 0 ]]; then
  echo "## Features"
  echo ""
  printf '%s\n' "${FEATS[@]}"
  echo ""
fi

if [[ ${#FIXES[@]} -gt 0 ]]; then
  echo "## Bug Fixes"
  echo ""
  printf '%s\n' "${FIXES[@]}"
  echo ""
fi

if [[ ${#REFACTORS[@]} -gt 0 ]]; then
  echo "## Refactors"
  echo ""
  printf '%s\n' "${REFACTORS[@]}"
  echo ""
fi

if [[ ${#DOCS[@]} -gt 0 ]]; then
  echo "## Documentation"
  echo ""
  printf '%s\n' "${DOCS[@]}"
  echo ""
fi

if [[ ${#CHORES[@]} -gt 0 ]]; then
  echo "## Chores"
  echo ""
  printf '%s\n' "${CHORES[@]}"
  echo ""
fi

if [[ ${#OTHERS[@]} -gt 0 ]]; then
  echo "## Other"
  echo ""
  printf '%s\n' "${OTHERS[@]}"
  echo ""
fi
