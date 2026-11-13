#!/usr/bin/env bash
# Publish a release the release workflow built: check it, draft it, attach its signature
# and publish it. One step per call, and each refuses unless the step before it is done.
#
# The release workflow only builds: it uploads the zip and the update manifest as the
# artifact release-<tag>. What users get is decided here, on the maintainer's machine. The
# signature itself is scripts/sign-release.sh's, run by the maintainer between draft and
# attach.
#
# Usage:
#   scripts/publish-release.sh check <tag>
#       refuse unless a release.yml run on the tag ref has succeeded, then download that
#       run's artifact, check the zip against the tag (scripts/check-release-zip.mjs) and
#       the manifest against the one this machine writes for that zip. It does not wait
#       for a run: watch it first (gh run watch).
#   scripts/publish-release.sh draft <tag>
#       create the draft release with the checked zip and manifest, and print the sign
#       command. The draft's body is empty.
#   scripts/publish-release.sh attach <tag>
#       refuse unless scripts/sign-release.sh --verify accepts the signature beside the
#       manifest, then upload it to the draft, download the draft's three assets back and
#       ask the toolkit inside that zip whether it trusts that manifest and signature, on
#       Godot 4.2 and 4.7. GODOT_BIN_4_2 and GODOT_BIN_4_7 name the two binaries.
#   scripts/publish-release.sh publish <tag>
#       the maintainer's step. Refuse unless attach passed for this draft, then publish
#       it as the latest release and check it: its attestation, each asset against it,
#       that it is immutable, and that an anonymous reader sees it as the latest.
#   scripts/publish-release.sh publish trust-<N> <tag>
#       a key rotation: publish the trust document the tag commits as trust/trust-<N>.json,
#       then the release, in one run, so no reader waits long between the two. The
#       document goes out as a prerelease that is never the latest.
#
# Exit 0 = done, 1 = refused, 2 = wrong usage or a missing tool.
#
# Each step leaves its result in dist-plugin/release-<tag>/, beside the files it checked:
# "checked" (the run, the tag's commit, the zip's and the manifest's SHA-256) and
# "reader-checked" (the draft's id and the SHA-256 of its three assets). The records stay on
# this machine because its checks are the ones that decide, and a record kept on GitHub
# could be rewritten by anyone who can write the release. A later step holds a record to
# the files beside it and to the draft: it downloads the draft's assets again and compares
# their hashes, so a draft that was replaced, or an asset that was swapped, is refused.
#
# GH_BIN and CURL_BIN name stand-ins for gh and curl, for tests.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=lib/update_test_env.sh
source "${REPO_ROOT}/scripts/lib/update_test_env.sh"

GH_BIN="${GH_BIN:-gh}"
CURL_BIN="${CURL_BIN:-curl}"

RELEASE_TAG='^v[0-9]+\.[0-9]+\.[0-9]+$'
DOCUMENT_TAG='^trust-[1-9][0-9]{0,8}$'
# The Godot versions the reader check runs on: the oldest the toolkit supports and the newest.
READER_MINORS="4.2 4.7"
READER_MARKER="READER_CHECK_RESULT "
READER_SECONDS=120
# How long an anonymous read of the latest release may trail a publish.
LATEST_TRIES=6
LATEST_PAUSE_SECONDS=5

SCRATCH=""
LATEST_SEEN=""

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show' "$0" | sed 's/^# \{0,1\}//'
}

refuse() {
  echo "refused: $*" >&2
  exit 1
}

setup_error() {
  echo "error: $*" >&2
  exit 2
}

remove_scratch() {
  if [[ -n "${SCRATCH}" ]]; then
    rm -rf "${SCRATCH}"
  fi
}

# Downloads are untrusted until compared, so each lands in a folder of its own that the
# run removes.
make_scratch() {
  mkdir -p "${WORK}"
  SCRATCH="$(mktemp -d "${WORK}/tmp.XXXXXX")"
  trap remove_scratch EXIT
}

# Sets the names every step shares from the tag $1, which must exist in this checkout.
use_tag() {
  TAG="$1"
  [[ "${TAG}" =~ ${RELEASE_TAG} ]] || setup_error "${TAG} is not a release tag (vX.Y.Z)."
  VERSION="${TAG#v}"
  COMMIT="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" | tr -d '\r')" \
    || refuse "this checkout has no tag ${TAG}."
  WORK="${REPO_ROOT}/dist-plugin/release-${TAG}"
  SHOWN_WORK="dist-plugin/release-${TAG}"
  ZIP_NAME="godot-mcp-toolkit-${VERSION}.zip"
  MANIFEST_NAME="godot-mcp-toolkit-${VERSION}.update.json"
  SIGNATURE_NAME="${MANIFEST_NAME}.sig"
  CHECKED="${WORK}/checked"
  READER_CHECKED="${WORK}/reader-checked"
}

# Prints the value a record $1 holds for the name $2.
record_value() {
  sed -n "s/^$2 //p" "$1" | tr -d '\r' | head -1
}

# Refuses unless check passed for this tag and the files it checked are still the ones here.
require_checked() {
  [[ -f "${CHECKED}" ]] || refuse "${TAG} has not been checked: run scripts/publish-release.sh check ${TAG} first."
  [[ "$(record_value "${CHECKED}" commit)" == "${COMMIT}" ]] \
    || refuse "the tag ${TAG} is at ${COMMIT}, not the commit that was checked. Run check again."
  local name
  for name in zip manifest; do
    local file="${WORK}/${ZIP_NAME}"
    [[ "${name}" == "manifest" ]] && file="${WORK}/${MANIFEST_NAME}"
    [[ -f "${file}" && "$(rf_sha256 "${file}")" == "$(record_value "${CHECKED}" "${name}")" ]] \
      || refuse "${file} is not the file that was checked. Run check again."
  done
}

# Prints "<id> <true|false>", the id of the one release that carries the tag $1 and whether
# it is a draft, or nothing when there is none. The list holds drafts, which a lookup by tag
# does not, and two drafts can carry one tag.
find_release() {
  local found
  found="$("${GH_BIN}" api --paginate "repos/{owner}/{repo}/releases?per_page=100" \
    --jq '.[] | select(.tag_name == "'"$1"'") | "\(.id) \(.draft)"' | tr -d '\r')" \
    || setup_error "could not list the repository's releases."
  if [[ "$(printf '%s\n' "${found}" | grep -c .)" -gt 1 ]]; then
    refuse "more than one release carries the tag $1. Delete the extra drafts on GitHub."
  fi
  printf '%s\n' "${found}"
}

# Prints the asset names of the release with id $1, byte-sorted.
asset_names() {
  "${GH_BIN}" api "repos/{owner}/{repo}/releases/$1/assets?per_page=100" --jq '.[].name' \
    | tr -d '\r' | LC_ALL=C sort
}

# Downloads the assets named from $3 on, of the release tagged $1, into the folder $2.
download_assets() {
  local tag="$1" folder="$2" name
  shift 2
  local patterns=()
  for name in "$@"; do
    patterns+=(--pattern "${name}")
  done
  mkdir -p "${folder}"
  "${GH_BIN}" release download "${tag}" --dir "${folder}" "${patterns[@]}" > /dev/null \
    || setup_error "could not download $* from the release ${tag}."
}

# Prints the tag an anonymous reader gets as the latest release of the repository $1
# (owner/name). No token goes with the request: this is what the toolkit's update check sees.
anonymous_latest() {
  "${CURL_BIN}" -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | tr -d '\r' | sed -nE 's/.*"tag_name": *"([^"]*)".*/\1/p' | head -1
}

# Succeeds once the anonymous latest release of $1 is a tag that matches the glob $2, and
# leaves the last tag read in LATEST_SEEN.
wait_for_latest() {
  local slug="$1" wanted="$2" try
  for (( try = 1; try <= LATEST_TRIES; try++ )); do
    LATEST_SEEN="$(anonymous_latest "${slug}" || true)"
    # shellcheck disable=SC2053 # the right side is a glob on purpose
    [[ -n "${LATEST_SEEN}" && "${LATEST_SEEN}" == ${wanted} ]] && return 0
    (( try < LATEST_TRIES )) && sleep "${LATEST_PAUSE_SECONDS}"
  done
  return 1
}

# Prints the number of the highest trust document the tag commits, or nothing.
highest_document() {
  git ls-tree --name-only "${TAG}" trust/ | tr -d '\r' \
    | sed -nE 's|^trust/trust-([1-9][0-9]*)\.json$|\1|p' | sort -n | tail -1
}

check() {
  local branches run found
  branches="$("${GH_BIN}" api "repos/{owner}/{repo}/git/matching-refs/heads/${TAG}" \
    --jq '.[] | select(.ref == "refs/heads/'"${TAG}"'") | .ref' | tr -d '\r')" \
    || setup_error "could not read the repository's branches."
  # A run is matched by the name of its ref, which a branch named like the tag would share,
  # and a branch run skips the workflow's tag-only checks.
  [[ -z "${branches}" ]] || refuse "the repository has a branch named ${TAG}, so a run on the tag cannot be told from one on the branch."
  run="$("${GH_BIN}" run list --workflow release.yml --commit "${COMMIT}" --branch "${TAG}" \
    --status success --limit 1 --json databaseId --jq '.[0].databaseId // empty' | tr -d '\r')" \
    || setup_error "could not list the release.yml runs."
  [[ -n "${run}" ]] || refuse "no release.yml run on the tag ref ${TAG} (${COMMIT}) has succeeded. Watch the tag's run (gh run watch), or dispatch release.yml on the tag ref."
  found="$(find_release "${TAG}")"
  [[ -z "${found}" ]] || refuse "a release for ${TAG} is already on GitHub. check comes before draft: to start over, delete the draft there."
  [[ -f scripts/check-release-zip.mjs ]] || setup_error "scripts/check-release-zip.mjs is missing."
  command -v node >/dev/null 2>&1 || setup_error "node is required."

  make_scratch
  local incoming="${SCRATCH}/artifact"
  mkdir "${incoming}"
  "${GH_BIN}" run download "${run}" --name "release-${TAG}" --dir "${incoming}" \
    || refuse "run ${run} has no artifact named release-${TAG}."
  local held wanted
  held="$(cd "${incoming}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  wanted="$(printf '%s\n' "${ZIP_NAME}" "${MANIFEST_NAME}" | LC_ALL=C sort)"
  [[ "${held}" == "${wanted}" ]] \
    || refuse "the artifact release-${TAG} must hold ${ZIP_NAME} and ${MANIFEST_NAME} only; it holds: ${held//$'\n'/, }"

  node scripts/check-release-zip.mjs "${incoming}/${ZIP_NAME}" "${TAG}" \
    || refuse "${ZIP_NAME} from run ${run} does not hold the tag's files."

  # The manifest's fields come from the tag, never from this checkout's working tree, so the
  # constants file is read where the helpers look for it, under a root of its own.
  local tag_root="${SCRATCH}/tag" min_godot compatible_server committed
  mkdir -p "$(dirname "${tag_root}/${CS_CONSTANT_FILE}")"
  git show "${TAG}:${CS_CONSTANT_FILE}" > "${tag_root}/${CS_CONSTANT_FILE}"
  min_godot="$(rf_min_godot "${tag_root}")"
  compatible_server="$(cs_current "${tag_root}")"
  committed="$(git log -1 --format=%ct "${COMMIT}" | tr -d '\r')"
  [[ -n "${min_godot}" && -n "${compatible_server}" && "${committed}" =~ ^[0-9]+$ ]] \
    || setup_error "could not read the manifest's fields from ${TAG}."
  # The expiry counts from the tag's commit, as rf_expires_at counts from HEAD in the build.
  rf_write_manifest "${incoming}/${ZIP_NAME}" "${VERSION}" "${min_godot}" "${compatible_server}" \
    "$((committed + RF_EXPIRY_SECONDS))" "${SCRATCH}/expected.update.json"
  if ! cmp -s "${SCRATCH}/expected.update.json" "${incoming}/${MANIFEST_NAME}"; then
    echo "  this machine writes: $(cat "${SCRATCH}/expected.update.json")" >&2
    echo "  the run built:       $(cat "${incoming}/${MANIFEST_NAME}")" >&2
    refuse "${MANIFEST_NAME} from run ${run} is not the manifest of that zip at ${TAG}."
  fi

  # A signature or a reader check left by an earlier build would vouch for other bytes.
  rm -f "${READER_CHECKED}" "${WORK}/${SIGNATURE_NAME}"
  mv "${incoming}/${ZIP_NAME}" "${incoming}/${MANIFEST_NAME}" "${WORK}/"
  printf 'run %s\ncommit %s\nzip %s\nmanifest %s\n' "${run}" "${COMMIT}" \
    "$(rf_sha256 "${WORK}/${ZIP_NAME}")" "$(rf_sha256 "${WORK}/${MANIFEST_NAME}")" > "${CHECKED}"
  echo "Checked ${TAG} from run ${run}: ${SHOWN_WORK}/${ZIP_NAME} and ${MANIFEST_NAME}."
  echo "Next: scripts/publish-release.sh draft ${TAG}"
}

draft() {
  require_checked
  local found
  found="$(find_release "${TAG}")"
  [[ -z "${found}" ]] || refuse "a release for ${TAG} is already on GitHub. To start over, delete the draft there."
  # --verify-tag stops gh from creating the tag when the remote has none.
  "${GH_BIN}" release create "${TAG}" --draft --verify-tag --title "${TAG}" --notes "" \
    "${WORK}/${ZIP_NAME}" "${WORK}/${MANIFEST_NAME}" \
    || setup_error "could not create the draft for ${TAG}."
  echo "Drafted ${TAG} with ${ZIP_NAME} and ${MANIFEST_NAME}."
  echo "Next, the maintainer signs: scripts/sign-release.sh ${SHOWN_WORK}/${MANIFEST_NAME} <private-key.pem>"
  echo "Then: scripts/publish-release.sh attach ${TAG}"
}

# Prints the first two fields of a binary's version, such as 4.2.
godot_minor() {
  "$1" --version 2>/dev/null | tr -d '\r' | head -1 | cut -d. -f1,2 || true
}

# Prints the binary named for the Godot version $1, refusing one of another version.
godot_for() {
  local name="GODOT_BIN_${1//./_}"
  local binary="${!name:-}"
  [[ -n "${binary}" ]] || setup_error "set ${name} to a Godot $1 binary."
  [[ "$(godot_minor "${binary}")" == "$1" ]] || setup_error "${name} (${binary}) is not Godot $1."
  printf '%s\n' "${binary}"
}

# The script the reader check runs inside a project that holds the release's addon.
write_reader_script() {
  cat > "$1" << 'GDSCRIPT'
@tool
extends SceneTree
## Asks the toolkit in this project whether it trusts a release.
##
## It reads the manifest and the signature named on the command line with the trust document
## this toolkit embeds and an empty store, which is what a fresh install holds.
## [codeblock]
## godot --headless --path <project> --script <this file> -- <manifest> <signature> <empty-folder>
## [/codeblock]
## The engine prints its own lines around the verdict, and its exit code is unreliable on
## Windows, so the verdict is the line that starts with [constant RESULT_MARKER].

const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")

## Prefix of the output line that carries the verdict.
const RESULT_MARKER := "READER_CHECK_RESULT "


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 3:
		print(RESULT_MARKER + "wrong arguments")
		quit(2)
		return
	var manifest := FileAccess.get_file_as_bytes(arguments[0])
	var signature := FileAccess.get_file_as_bytes(arguments[1])
	var source := {"trust_store": arguments[2]}
	var trusted := ReleaseSignature.is_trusted(manifest, signature, null, source)
	# A reader that trusted everything would pass the line above, so the same signature
	# over a changed manifest must be refused.
	var changed := manifest.duplicate()
	if not changed.is_empty():
		changed[0] = changed[0] ^ 1
	var trusts_changed := ReleaseSignature.is_trusted(changed, signature, null, source)
	if trusted and not trusts_changed:
		print(RESULT_MARKER + "trusted")
		quit(0)
	elif trusted:
		print(RESULT_MARKER + "trusts a changed manifest")
		quit(1)
	else:
		print(RESULT_MARKER + "not trusted")
		quit(1)
GDSCRIPT
}

# Refuses unless the toolkit inside the zip $3, run by the Godot binary $1 of version $2,
# trusts the manifest $4 with the signature $5.
reader_check() {
  local godot="$1" minor="$2" zip="$3" manifest="$4" signature="$5"
  local project="${SCRATCH}/reader-${minor}/project" store="${SCRATCH}/reader-${minor}/store" output
  mkdir -p "${project}" "${store}"
  unzip -q "${zip}" -d "${project}"
  printf 'config_version=5\n\n[application]\n\nconfig/name="Release reader check"\n' > "${project}/project.godot"
  write_reader_script "${project}/reader_check.gd"
  output="$("$(ut_timeout_bin)" "${READER_SECONDS}" "${godot}" --headless --path "${project}" \
    --script "${project}/reader_check.gd" -- "${manifest}" "${signature}" "${store}" 2>&1 | tr -d '\r')" || true
  if ! grep -qxF "${READER_MARKER}trusted" <<< "${output}"; then
    printf '%s\n' "${output}" | sed 's/^/  /' >&2
    refuse "on Godot ${minor}, the toolkit in the draft's zip does not trust the draft's manifest and signature."
  fi
  echo "  Godot ${minor}: the toolkit in the draft's zip trusts the draft's manifest and signature"
}

attach() {
  require_checked
  local signature="${WORK}/${SIGNATURE_NAME}"
  [[ -f "${signature}" ]] \
    || refuse "no signature at ${SHOWN_WORK}/${SIGNATURE_NAME}. The maintainer signs first: scripts/sign-release.sh ${SHOWN_WORK}/${MANIFEST_NAME} <private-key.pem>"
  bash "${REPO_ROOT}/scripts/sign-release.sh" --verify "${WORK}/${MANIFEST_NAME}" \
    || refuse "scripts/sign-release.sh --verify does not accept ${SHOWN_WORK}/${SIGNATURE_NAME}."
  command -v unzip >/dev/null 2>&1 || setup_error "unzip is required."
  local minor binaries=()
  for minor in ${READER_MINORS}; do
    binaries+=("$(godot_for "${minor}")")
  done

  local found id is_draft
  found="$(find_release "${TAG}")"
  [[ -n "${found}" ]] || refuse "${TAG} has no draft: run scripts/publish-release.sh draft ${TAG} first."
  read -r id is_draft <<< "${found}"
  [[ "${is_draft}" == "true" ]] || refuse "${TAG} is already published."
  local names both all
  names="$(asset_names "${id}")"
  both="$(printf '%s\n' "${ZIP_NAME}" "${MANIFEST_NAME}" | LC_ALL=C sort)"
  all="$(printf '%s\n' "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}" | LC_ALL=C sort)"
  [[ "${names}" == "${both}" || "${names}" == "${all}" ]] \
    || refuse "the draft for ${TAG} must hold the zip, the manifest and at most the signature; it holds: ${names//$'\n'/, }"

  make_scratch
  local back="${SCRATCH}/draft"
  # Nothing is added to a draft that does not hold the files check passed.
  download_assets "${TAG}" "${back}" "${ZIP_NAME}" "${MANIFEST_NAME}"
  cmp -s "${back}/${ZIP_NAME}" "${WORK}/${ZIP_NAME}" && cmp -s "${back}/${MANIFEST_NAME}" "${WORK}/${MANIFEST_NAME}" \
    || refuse "the draft for ${TAG} does not hold the zip and manifest that were checked. Delete the draft and run draft again."
  if [[ "${names}" == "${both}" ]]; then
    "${GH_BIN}" release upload "${TAG}" "${signature}" || setup_error "could not upload ${SIGNATURE_NAME}."
  fi
  download_assets "${TAG}" "${back}" "${SIGNATURE_NAME}"
  cmp -s "${back}/${SIGNATURE_NAME}" "${signature}" \
    || refuse "the draft's ${SIGNATURE_NAME} is not the one here. Delete that asset from the draft and run attach again."

  # An earlier pass says nothing about this run's bytes.
  rm -f "${READER_CHECKED}"
  echo "The reader check, on the bytes downloaded back from the draft:"
  local index=0
  for minor in ${READER_MINORS}; do
    reader_check "${binaries[${index}]}" "${minor}" "${back}/${ZIP_NAME}" "${back}/${MANIFEST_NAME}" "${back}/${SIGNATURE_NAME}"
    index=$((index + 1))
  done
  printf 'release %s\nzip %s\nmanifest %s\nsignature %s\n' "${id}" "$(rf_sha256 "${back}/${ZIP_NAME}")" \
    "$(rf_sha256 "${back}/${MANIFEST_NAME}")" "$(rf_sha256 "${back}/${SIGNATURE_NAME}")" > "${READER_CHECKED}"
  echo "Attached ${SIGNATURE_NAME} to the draft for ${TAG}."
  echo "Next, the maintainer publishes: scripts/publish-release.sh publish ${TAG}"
}

# Publishes the trust document trust-$1 from the bytes the tag commits, unless it is already
# out with those bytes. A published document can never be replaced, so a run that stopped
# after this step must be able to run again.
publish_document() {
  local number="$1" slug="$2" tag="trust-$1" file="trust-$1.json" found is_draft="true"
  local committed="${SCRATCH}/committed/${file}" back="${SCRATCH}/document"
  mkdir -p "$(dirname "${committed}")"
  git show "${TAG}:trust/${file}" > "${committed}"
  found="$(find_release "${tag}")"
  if [[ -z "${found}" ]]; then
    # A document that became the latest release would stop every update check, which reads
    # the latest tag as a version.
    "${GH_BIN}" release create "${tag}" --draft --prerelease --latest=false --title "${tag}" \
      --notes "Trust document ${number}." "${committed}" \
      || setup_error "could not create the draft for ${tag}."
  else
    read -r _ is_draft <<< "${found}"
  fi
  # The release workflow read the committed bytes, not the uploaded ones.
  download_assets "${tag}" "${back}" "${file}"
  if ! cmp -s "${back}/${file}" "${committed}"; then
    [[ "${is_draft}" == "true" ]] \
      || refuse "${tag} is published with bytes that are not ${TAG}'s trust/${file}. Nothing can replace it: stop and investigate."
    refuse "the draft for ${tag} does not hold ${TAG}'s trust/${file}. Delete the draft and run again."
  fi
  if [[ "${is_draft}" == "true" ]]; then
    "${GH_BIN}" release edit "${tag}" --draft=false --prerelease --latest=false \
      || setup_error "could not publish ${tag}."
    echo "Published ${tag}."
  else
    echo "${tag} is already published with ${TAG}'s bytes."
  fi
  wait_for_latest "${slug}" "v*" \
    || refuse "after ${tag}, an anonymous reader's latest release is '${LATEST_SEEN}', not a version. Repair it with gh release edit v<the last version> --latest, then run again."
}

publish() {
  local document="$1"
  require_checked
  [[ -f "${READER_CHECKED}" ]] \
    || refuse "the reader check has not passed for ${TAG}: run scripts/publish-release.sh attach ${TAG} first."
  local found id is_draft
  found="$(find_release "${TAG}")"
  [[ -n "${found}" ]] || refuse "${TAG} has no draft: run draft, the sign command and attach first."
  read -r id is_draft <<< "${found}"
  [[ "${id}" == "$(record_value "${READER_CHECKED}" release)" ]] \
    || refuse "the release for ${TAG} is not the draft the reader check passed for. Run attach again."
  local all
  all="$(printf '%s\n' "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}" | LC_ALL=C sort)"
  [[ "$(asset_names "${id}")" == "${all}" ]] \
    || refuse "the release for ${TAG} must hold the zip, the manifest and the signature, and nothing else."

  make_scratch
  local back="${SCRATCH}/draft" name file
  download_assets "${TAG}" "${back}" "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}"
  for name in zip manifest signature; do
    case "${name}" in
      zip) file="${ZIP_NAME}" ;;
      manifest) file="${MANIFEST_NAME}" ;;
      *) file="${SIGNATURE_NAME}" ;;
    esac
    [[ "$(rf_sha256 "${back}/${file}")" == "$(record_value "${READER_CHECKED}" "${name}")" ]] \
      || refuse "the release's ${file} is not the one the reader check passed for. Run attach again."
  done

  local highest slug
  highest="$(highest_document)"
  if [[ -n "${document}" ]]; then
    [[ "${document}" == "trust-${highest}" && "${highest}" -ge 2 ]] \
      || refuse "${document} is not the highest trust document ${TAG} commits (trust-${highest:-none}), or it is trust-1, which is never hosted."
  elif [[ -n "${highest}" && "${highest}" -ge 2 ]]; then
    found="$(find_release "trust-${highest}")"
    [[ "${found}" == *" false" ]] \
      || refuse "${TAG} embeds trust-${highest}, which is not published. Publish both: scripts/publish-release.sh publish trust-${highest} ${TAG}"
  fi
  slug="$("${GH_BIN}" repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r')" \
    || setup_error "could not read the repository's name."

  if [[ -n "${document}" ]]; then
    publish_document "${highest}" "${slug}"
  fi
  if [[ "${is_draft}" == "true" ]]; then
    "${GH_BIN}" release edit "${TAG}" --draft=false --latest || setup_error "could not publish ${TAG}."
    echo "Published ${TAG}."
  else
    echo "${TAG} is already published; checking it again."
  fi

  # Past this point the release is public and, with immutable releases on, final: a failed
  # line below is fixed by a new release, so every line runs before the verdict.
  local failed=0 immutable
  "${GH_BIN}" release verify "${TAG}" || { echo "  FAIL: gh release verify ${TAG}" >&2; failed=1; }
  for file in "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}"; do
    "${GH_BIN}" release verify-asset "${TAG}" "${WORK}/${file}" \
      || { echo "  FAIL: gh release verify-asset ${TAG} ${file}" >&2; failed=1; }
  done
  immutable="$("${GH_BIN}" api "repos/{owner}/{repo}/releases/${id}" --jq .immutable | tr -d '\r' || true)"
  [[ "${immutable}" == "true" ]] || { echo "  FAIL: the release is not immutable (immutable: ${immutable:-unread})" >&2; failed=1; }
  wait_for_latest "${slug}" "${TAG}" \
    || { echo "  FAIL: an anonymous reader's latest release is '${LATEST_SEEN}', not ${TAG}" >&2; failed=1; }
  if [[ "${failed}" -ne 0 ]]; then
    echo "error: ${TAG} is published, and a check on it failed. It cannot be withdrawn: fix forward." >&2
    exit 1
  fi
  echo "${TAG} is published, attested, immutable and the latest release."
  echo "Next, the ledger: add this line to trust/released-manifests.txt through a pull request from chore/ledger-${VERSION}:"
  echo "  ${VERSION} $(record_value "${READER_CHECKED}" manifest)"
}

case "${1:-}" in
  -h | --help | "")
    usage
    exit 0
    ;;
  check | draft | attach)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    use_tag "$2"
    "$1"
    ;;
  publish)
    if [[ $# -eq 3 ]]; then
      [[ "$2" =~ ${DOCUMENT_TAG} ]] || setup_error "$2 is not a trust document tag (trust-N)."
      use_tag "$3"
      publish "$2"
    elif [[ $# -eq 2 ]]; then
      use_tag "$2"
      publish ""
    else
      usage >&2
      exit 2
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
