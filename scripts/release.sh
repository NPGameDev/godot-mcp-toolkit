#!/usr/bin/env bash
#
# release.sh — cut a release of the toolkit (this repo).
#
# Validates the version, runs the pre-flights, bumps plugin.cfg, rolls the
# CHANGELOG, pauses for you to curate, then commits and creates an ANNOTATED tag.
# It does NOT push. See RELEASING.md for the full release process.
#
# The toolkit and the server version INDEPENDENTLY (each its own tags + cadence),
# so this script releases only the toolkit — releasing the toolkit alone is
# correct, not an edge case. There is no coordination warning.
#
# Runs under Git Bash / POSIX sh on Windows: quote every path (working trees live
# under OneDrive paths with spaces) and CR-strip any capture from a Windows shim.
set -euo pipefail

# ── Location ────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PLUGIN_CFG="addons/godot_mcp_toolkit/plugin.cfg"
CHANGELOG="CHANGELOG.md"
CROSS_VERSION_YML=".github/workflows/cross-version.yml"

# ── Usage / argument parsing ────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: ./scripts/release.sh <toolkit-version> [--dry-run]

Examples:
  ./scripts/release.sh 1.1.0            # release the toolkit
  ./scripts/release.sh 1.1.0 --dry-run  # validate + report; write nothing
EOF
}

VERSION=""
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown flag '${arg}'." >&2; usage; exit 1 ;;
    *)
      if [[ -n "${VERSION}" ]]; then
        echo "error: unexpected extra argument '${arg}'." >&2; usage; exit 1
      fi
      VERSION="${arg}"
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  echo "error: a target version is required." >&2
  usage
  exit 1
fi

TAG="v${VERSION}"

# ── Failure-path undo print ─────────────────────────────────────────────────
# Capture the pre-run HEAD; on an abort AFTER a commit or tag was created, print
# the exact undo commands. Print-only — this script never rewinds anything.
PRE_RUN_SHA="$(git rev-parse HEAD)"
COMMIT_MADE=0
TAG_MADE=0

on_exit() {
  local code=$?
  if [[ ${code} -ne 0 && ( ${COMMIT_MADE} -eq 1 || ${TAG_MADE} -eq 1 ) ]]; then
    echo ""
    echo "── Aborted after a mutation. Undo with: ──────────────────────────────"
    if [[ ${TAG_MADE} -eq 1 ]]; then
      echo "  git -C \"${REPO_ROOT}\" tag -d ${TAG}"
    fi
    echo "  git -C \"${REPO_ROOT}\" reset --hard ${PRE_RUN_SHA}"
    echo "──────────────────────────────────────────────────────────────────────"
  fi
}
trap on_exit EXIT

fail() { echo "::error::$*" >&2; echo "error: $*" >&2; exit 1; }

# ── Version-format validation ───────────────────────────────────────────────
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "version '${VERSION}' is not a well-formed semver (expected X.Y.Z)."
fi

# ── Current version from plugin.cfg (the toolkit's single version surface) ───
CURRENT_VERSION="$(grep -E '^version="' "${PLUGIN_CFG}" | sed -E 's/version="([^"]+)".*/\1/')"
if [[ -z "${CURRENT_VERSION}" ]]; then
  fail "could not read version from ${PLUGIN_CFG}."
fi

# ── Monotonicity vs the highest existing v* tag ─────────────────────────────
# The git tag is the toolkit's release authority (it publishes no npm package).
LATEST_TAG="$(git tag -l 'v*' | sort -V | tail -1 || true)"
if [[ -n "${LATEST_TAG}" ]]; then
  LATEST_VER="${LATEST_TAG#v}"
  if [[ "${VERSION}" == "${LATEST_VER}" ]]; then
    # Equal is allowed only on the untagged recovery path (the target-available
    # check below re-confirms the tag is genuinely absent) — a re-run before the
    # tag was pushed.
    :
  else
    HIGHEST="$(printf '%s\n%s\n' "${VERSION}" "${LATEST_VER}" | sort -V | tail -1)"
    if [[ "${HIGHEST}" != "${VERSION}" ]]; then
      fail "version ${VERSION} is not greater than the highest tag ${LATEST_TAG}."
    fi
  fi
else
  # No v* tag yet — any valid target at or above the manifest is fine on this
  # first-release / untagged path.
  HIGHEST="$(printf '%s\n%s\n' "${VERSION}" "${CURRENT_VERSION}" | sort -V | tail -1)"
  if [[ "${HIGHEST}" != "${VERSION}" ]]; then
    fail "version ${VERSION} is below the current plugin.cfg version ${CURRENT_VERSION}."
  fi
fi

# ── Fetch-first, then on-main / clean / up-to-date ──────────────────────────
echo "→ Fetching origin/main…"
git fetch origin main

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "${CURRENT_BRANCH}" == "main" ]] || fail "not on main (on '${CURRENT_BRANCH}')."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "working tree is not clean. Commit or stash first."
fi

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main)"
[[ "${LOCAL_HEAD}" == "${REMOTE_HEAD}" ]] || \
  fail "HEAD (${LOCAL_HEAD}) is not up to date with origin/main (${REMOTE_HEAD})."

# ── Pre-flight — target-version available ───────────────────────────────────
if [[ -n "$(git tag -l "${TAG}")" ]]; then
  fail "tag ${TAG} already exists locally — a genuine collision."
fi
if [[ -n "$(git ls-remote --tags origin "refs/tags/${TAG}")" ]]; then
  fail "tag ${TAG} already exists on origin — a genuine collision."
fi

# ── Pre-flight — code-identical sibling pin ─────────────────────────────────
# The tag-fired behavioral gate checks the server out at SIBLING_PIN_SERVER. That
# pin must be code-identical to the server's main (a stale pin certifies a drifted
# sibling). Allow only a metadata-only offset (the pin/version-bump commits) — any
# other changed path aborts.
SIBLING_PIN_SERVER="$(grep 'SIBLING_PIN_SERVER:' "${CROSS_VERSION_YML}" | sed -E 's/.*"([0-9a-f]+)".*/\1/')"
[[ -n "${SIBLING_PIN_SERVER}" ]] || fail "could not read SIBLING_PIN_SERVER from ${CROSS_VERSION_YML}."

SERVER_REPO="${GODOT_MCP_SERVER_REPO:-../godot-mcp-server}"
if [[ ! -d "${SERVER_REPO}/.git" ]]; then
  fail "server sibling repo not found at '${SERVER_REPO}' (set GODOT_MCP_SERVER_REPO)."
fi

echo "→ Fetching the server sibling's origin/main…"
git -C "${SERVER_REPO}" fetch origin main

# Allowlist: metadata paths whose drift from the pin is expected (the pin-bump +
# version-bump commits touch them). Everything else must be code-identical.
CHANGED_PATHS="$(git -C "${SERVER_REPO}" diff --name-only "${SIBLING_PIN_SERVER}..origin/main" || true)"
OFFENDING=""
while IFS= read -r path; do
  [[ -z "${path}" ]] && continue
  case "${path}" in
    .github/workflows/cross-version.yml) ;;   # sibling-pin bump lives here
    *) OFFENDING="${OFFENDING}${path}"$'\n' ;;
  esac
done <<< "${CHANGED_PATHS}"

if [[ -n "${OFFENDING}" ]]; then
  echo "::error::The pinned server (${SIBLING_PIN_SERVER}) is not code-identical to server main." >&2
  echo "Offending paths:" >&2
  echo "${OFFENDING}" >&2
  fail "Run the bump-before-tag ritual first — bump SIBLING_PIN_SERVER to the certified server revision in a [run-cross-version-ci] commit, let CI go green, then re-run."
fi

# ── Pre-flight — CI green on both HEADs ─────────────────────────────────────
check_ci_green() {
  local repo_slug="$1" sha="$2"
  local json conclusion
  json="$(gh api "repos/${repo_slug}/commits/${sha}/check-runs" 2>/dev/null || echo '')"
  [[ -z "${json}" ]] && return 2
  # Any non-success (or a still-running) conclusion => not green.
  conclusion="$(echo "${json}" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{
        const runs=(JSON.parse(s).check_runs)||[];
        if(runs.length===0){process.stdout.write("empty");return;}
        for(const r of runs){
          if(r.status!=="completed"){process.stdout.write("pending");return;}
          if(r.conclusion!=="success"&&r.conclusion!=="neutral"&&r.conclusion!=="skipped"){process.stdout.write("red");return;}
        }
        process.stdout.write("green");
      }catch(e){process.stdout.write("error");}
    });
  ')"
  [[ "${conclusion}" == "green" ]] && return 0
  return 1
}

SERVER_HEAD="$(git -C "${SERVER_REPO}" rev-parse origin/main)"
if command -v gh >/dev/null 2>&1; then
  echo "→ Checking CI on both HEADs…"
  gh_ok=1
  check_ci_green "NPGameDev/godot-mcp-toolkit" "${LOCAL_HEAD}" || gh_ok=0
  check_ci_green "NPGameDev/godot-mcp-server" "${SERVER_HEAD}" || gh_ok=0
  if [[ ${gh_ok} -ne 1 ]]; then
    fail "CI is not green (or is pending) on both HEADs. Wait for green, then re-run."
  fi
  echo "  CI green on both HEADs."
else
  echo "⚠ gh CLI not available — cannot verify CI is green on both HEADs."
  read -r -p "Confirm CI is green on toolkit ${LOCAL_HEAD} and server ${SERVER_HEAD}? [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || fail "CI-green confirmation declined."
fi

# ── Pre-flight — manual-gate reminder ───────────────────────────────────────
cat <<'EOF'

── Manual pre-release gate ───────────────────────────────────────────────────
Before tagging, the interactive checks CI cannot reach must be green:
  • export-strip (EX5–EX7)
  • connection stability
  • security
  • human + MCP concurrent editing
See docs/dev/release-checklist.md and work through it.
──────────────────────────────────────────────────────────────────────────────
EOF
read -r -p "Has the manual pre-release gate passed? [y/N] " reply
[[ "${reply}" == "y" || "${reply}" == "Y" ]] || fail "manual pre-release gate not confirmed."

# ── --dry-run short-circuit ─────────────────────────────────────────────────
TAGGED_COMMIT_PREVIEW="(the release commit — created after the CHANGELOG pause)"
if [[ ${DRY_RUN} -eq 1 ]]; then
  cat <<EOF

── DRY RUN — no writes, no commit, no tag ────────────────────────────────────
Would bump ${PLUGIN_CFG}: ${CURRENT_VERSION} → ${VERSION}
Would roll ${CHANGELOG}: '## [Unreleased]' → '## [${VERSION}] - $(date +%F)'
Would commit (chore(release): ${TAG}) staging only ${PLUGIN_CFG} + ${CHANGELOG}
Would create ANNOTATED tag ${TAG} carrying the rolled CHANGELOG section

Asset submission values (transcribe into the web form; RELEASING.md → Asset distribution):
  Version:          ${VERSION}
  Download Commit:  ${TAGGED_COMMIT_PREVIEW}
  Zip name:         godot-mcp-toolkit-${VERSION}.zip
  Target:           Godot Asset Store (store.godotengine.org) — primary;
                    legacy Asset Library while it still accepts submissions
──────────────────────────────────────────────────────────────────────────────
EOF
  echo "Dry run complete — nothing was written."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Mutation path — bump → roll → PAUSE → commit → annotated tag
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. Bump plugin.cfg (edit only the version= line; preserve the file's EOL) ─
#    Substitute only the version= line and write back, so the edit never flips
#    the whole file's line endings.
TMP_CFG="${PLUGIN_CFG}.tmp.$$"
awk -v ver="${VERSION}" '
  /^version="/ { sub(/^version="[^"]*"/, "version=\"" ver "\""); print; next }
  { print }
' "${PLUGIN_CFG}" > "${TMP_CFG}"
mv "${TMP_CFG}" "${PLUGIN_CFG}"

NEW_CFG_VERSION="$(grep -E '^version="' "${PLUGIN_CFG}" | sed -E 's/version="([^"]+)".*/\1/')"
[[ "${NEW_CFG_VERSION}" == "${VERSION}" ]] || fail "plugin.cfg bump failed (got '${NEW_CFG_VERSION}')."
echo "✓ ${PLUGIN_CFG} bumped to ${VERSION}"

# ── 2. Roll the CHANGELOG ────────────────────────────────────────────────────
#    Keep-a-Changelog bracketed heading: '## [Unreleased]' → '## [X.Y.Z] - date',
#    with a fresh empty '## [Unreleased]' above. No KaC link-refs to maintain.
if ! grep -qF "## [Unreleased]" "${CHANGELOG}"; then
  fail "no '## [Unreleased]' heading in ${CHANGELOG} — cannot roll."
fi

RELEASE_DATE="$(date +%F)"
SECTION_FILE="${TMPDIR:-C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude}/release-changelog-${VERSION}.$$.md"
mkdir -p "$(dirname "${SECTION_FILE}")"

TMP_CL="${CHANGELOG}.tmp.$$"
awk -v ver="${VERSION}" -v date="${RELEASE_DATE}" '
  {
    if ($0 == "## [Unreleased]") {
      print "## [Unreleased]";
      print "";
      print "## [" ver "] - " date;
    } else {
      print $0;
    }
  }
' "${CHANGELOG}" > "${TMP_CL}"
mv "${TMP_CL}" "${CHANGELOG}"
echo "✓ ${CHANGELOG} rolled: [Unreleased] → [${VERSION}] - ${RELEASE_DATE}"

# Warn (do not abort) if the rolled section is empty.
ROLLED_BODY="$(awk -v ver="${VERSION}" '
  index($0, "## [" ver "]") == 1 { grab=1; next }
  grab && index($0, "## ") == 1 { exit }
  grab { print }
' "${CHANGELOG}" | grep -v '^[[:space:]]*$' || true)"
if [[ -z "${ROLLED_BODY}" ]]; then
  echo "⚠ The rolled [${VERSION}] section is empty — curate it during the pause below."
  echo "  (Draft source only, NEVER piped over ${CHANGELOG}:"
  echo "   scripts/generate-changelog.sh --since=${LATEST_TAG:-v${CURRENT_VERSION}})"
fi

# ── 3. PAUSE for curation ────────────────────────────────────────────────────
echo ""
read -r -p "Review/curate the rolled CHANGELOG section now. Continue? [y/N] " reply
[[ "${reply}" == "y" || "${reply}" == "Y" ]] || fail "release paused — curation not confirmed."

# On resume, re-verify only the expected files changed (the pause breaks the
# clean-tree assumption).
UNEXPECTED="$(git status --porcelain | grep -vE " (${PLUGIN_CFG}|${CHANGELOG})$" || true)"
if [[ -n "${UNEXPECTED}" ]]; then
  echo "::error::Unexpected changes in the working tree after the pause:" >&2
  echo "${UNEXPECTED}" >&2
  fail "only ${PLUGIN_CFG} and ${CHANGELOG} may change during a release."
fi

# ── 4. Commit (stage ONLY the expected paths) ───────────────────────────────
git add "${PLUGIN_CFG}" "${CHANGELOG}"
git commit -m "chore(release): ${TAG}"
COMMIT_MADE=1
TAGGED_COMMIT="$(git rev-parse HEAD)"
echo "✓ Commit created: ${TAGGED_COMMIT}"

# ── 5. Annotated tag (carrying the rolled section) — never amend after ──────
awk -v ver="${VERSION}" '
  index($0, "## [" ver "]") == 1 { grab=1 }
  grab && index($0, "## ") == 1 && index($0, "## [" ver "]") != 1 { exit }
  grab { print }
' "${CHANGELOG}" > "${SECTION_FILE}"
# --cleanup=verbatim: the section is Markdown; without it git strips every
# '#'-leading line as a comment, gutting the '## [X.Y.Z]' header and '###'
# subheadings from the tag message (and thus the GitHub Release body).
git tag -a "${TAG}" --cleanup=verbatim -F "${SECTION_FILE}"
TAG_MADE=1
echo "✓ Annotated tag ${TAG} created"
rm -f "${SECTION_FILE}"

# ── Summary + AssetLib/Store block + push instructions (does NOT push) ──────
cat <<EOF

✓ toolkit bumped to ${TAG} (CHANGELOG curated and committed)
✓ Commit created, annotated tag applied  (server untouched — independent versioning)

Next steps:
  1. Push toolkit: cd "${REPO_ROOT}" && git push origin main ${TAG}
  2. The tag fires the GATED release workflow — the full behavioral matrix runs
     first; the GH Release (with the zip attached) only fires if it is green. A red
     leg blocks the release (by design). Transient failure? Re-dispatch release.yml
     ON the tag ref with dry-run: false — do not delete/re-push the tag.

Asset submission values (transcribe into the web form; RELEASING.md → Asset distribution):
  Version:          ${VERSION}
  Download Commit:  ${TAGGED_COMMIT}
  Zip name:         godot-mcp-toolkit-${VERSION}.zip
  Target:           Godot Asset Store (store.godotengine.org) — primary;
                    legacy Asset Library while it still accepts submissions
EOF
