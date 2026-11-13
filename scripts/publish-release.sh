#!/usr/bin/env bash
# Publish a release the release workflow built: check it, draft it, attach its signature
# and publish it. One step per call, and each refuses unless the step before it is done.
#
# The release workflow only builds: it uploads the zip and the update manifest as the
# artifact release-<tag>. What users get is decided here, on the maintainer's machine. The
# signature itself is scripts/sign-release.sh's, run by the maintainer in the signing
# account between draft and attach.
#
# A release carries its zip, its manifest, the manifest's .sig and every trust document the
# tag commits from trust-2.json up, byte for byte: a client reads the chain of keys from the
# release it is about to install.
#
# Usage:
#   scripts/publish-release.sh check <tag>
#       refuse unless a release.yml run on the tag ref has succeeded, then download that
#       run's artifact, check the zip against the tag (scripts/check-release-zip.mjs) and
#       the manifest against the one this machine writes for that zip. It does not wait
#       for a run: watch it first (gh run watch).
#   scripts/publish-release.sh draft <tag>
#       create the draft release with the checked zip and manifest and the tag's trust
#       documents, leave a copy of the zip in a new folder the signing account can read,
#       and print the sign command. The draft's body is empty. The folder is
#       publish-release-<tag>.<random> under /Users/Shared; PUBLISH_RELEASE_HANDOFF_ROOT
#       names another root. A folder an earlier draft of the tag left there is refused,
#       not removed: the signing account must find one zip for the tag.
#   scripts/publish-release.sh attach <tag> [<folder>]
#       <folder> is the one scripts/sign-release.sh printed as OUT. Without it, the one
#       folder named sign-release-<tag>.<letters and digits> under /Users/Shared is taken,
#       and none or several is refused; SIGN_RELEASE_OUT_ROOT names another root, as it
#       does for the sign. Refuse unless the folder's manifest is the checked one,
#       scripts/sign-release.sh --verify accepts its signature, the draft holds the
#       checked zip and manifest and the tag's trust documents, and it drops or changes
#       no trust document of the latest release. Then upload the signature to the draft,
#       download it back and ask the toolkit inside the draft's zip whether it trusts
#       that manifest and signature, on Godot 4.2 and 4.7: as a fresh install, and as an
#       install that starts from trust-1.json and takes the draft's trust documents in
#       order. GODOT_BIN_4_2 and GODOT_BIN_4_7 name the two binaries.
#   scripts/publish-release.sh publish <tag>
#       the maintainer's step. Check this checkout, its origin, the tag and the tag's
#       trust documents, then the draft: its assets downloaded back, the zip against the
#       tag, the manifest against the one this machine writes, the signature, the trust
#       documents, that the repository's releases are immutable and that the latest
#       release is an older version. Only then publish it as the latest release and check
#       it: its attestation, each asset against it, the names of its assets, that it is
#       immutable, and that an anonymous reader sees it as the latest. GitHub has no call
#       that checks a draft and publishes it as one step: the draft and its assets are
#       read again directly before the publish, and an asset added after that read is
#       found only by the checks that follow, on a release that can no longer change.
#       attach and publish refuse a draft marked a pre-release.
#
# Exit 0 = done, 1 = refused, 2 = wrong usage or a missing tool.
#
# Every call to GitHub names the repository scripts/lib/release_identity.sh pins, and every
# step first refuses a variable that would aim git or gh elsewhere and an origin that is not
# the pinned one (scripts/lib/release_checks.sh).
#
# Each step leaves its result in dist-plugin/release-<tag>/, beside the files it checked:
# "checked" (the run, the tag's commit, the zip's and the manifest's SHA-256) and
# "reader-checked" (the draft's id and the SHA-256 of its zip, manifest and signature). The
# records only keep the steps in order. Anything that can write this checkout can write
# them, so publish decides on what it reads itself from the tag, from origin and from the
# draft's bytes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=lib/update_test_env.sh
source "${REPO_ROOT}/scripts/lib/update_test_env.sh"
# shellcheck source=lib/release_checks.sh
source "${REPO_ROOT}/scripts/lib/release_checks.sh"

TRUST_DOCUMENT_NAME='^trust-.*\.json$'
# The Godot versions the reader check runs on: the oldest the toolkit supports and the newest.
READER_MINORS="4.2 4.7"
READER_MARKER="READER_CHECK_RESULT "
READER_SECONDS=120
# How long an anonymous read of the latest release may trail a publish.
LATEST_TRIES=6
LATEST_PAUSE_SECONDS=5

SCRATCH=""
# The folder draft made for the signing account, until the draft that goes with it exists.
UNFINISHED_HANDOFF=""
LATEST_SEEN=""
LATEST_TAG=""
LATEST_DOCUMENTS=""
TAG_TRUST=""
DOCUMENTS=()

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

# Runs on every exit: removes the run's scratch folder, and the folder draft made for the
# signing account when the run ends before its draft exists.
clean_up() {
  if [[ -n "${SCRATCH}" ]]; then
    rm -rf "${SCRATCH}"
  fi
  if [[ -n "${UNFINISHED_HANDOFF}" ]]; then
    rm -rf "${UNFINISHED_HANDOFF}"
  fi
}

# Downloads are untrusted until compared, so each lands in a folder of its own that the
# run removes.
make_scratch() {
  mkdir -p "${WORK}"
  SCRATCH="$(mktemp -d "${WORK}/tmp.XXXXXX")"
  TAG_TRUST="${SCRATCH}/tag-trust"
  mkdir "${TAG_TRUST}"
  trap clean_up EXIT
}

# Prints the text $1 on one line with every byte a terminal could act on replaced: a
# downloaded file's bytes and a name read from a folder are shown, never obeyed.
shown() {
  printf '%s' "${1//$'\n'/, }" | rc_printable
}

# Prints the file $1 the same way.
shown_file() {
  shown "$(cat "$1")"
}

# Every step starts here, before it reads git or GitHub: a variable such as GH_HOST or
# GIT_DIR, or another origin, would have each call below answer for another repository. A
# shared check prints its own refusal.
require_pinned_repository() {
  rc_check_environment || exit 1
  rc_check_origin || exit 1
}

# Sets the names every step shares from the tag $1, which must exist in this checkout.
use_tag() {
  TAG="$1"
  [[ "${TAG}" =~ ${RC_RELEASE_TAG} ]] || setup_error "${TAG} is not a release tag (vX.Y.Z)."
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

# Prints its arguments one per line, byte-sorted, the order asset names are compared in.
sorted_names() {
  printf '%s\n' "$@" | LC_ALL=C sort
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

# Sets DOCUMENTS to the names of the trust documents a release of this tag carries, once
# RC_TRUST_N holds the number of the tag's highest one. trust-1.json is never an asset: every
# client that reads a chain embeds it or a later document.
name_documents() {
  local number
  DOCUMENTS=()
  for (( number = 2; number <= RC_TRUST_N; number++ )); do
    DOCUMENTS+=("trust-${number}.json")
  done
}

# Checks the tag's trust documents, leaves them in ${TAG_TRUST} and names the ones a release
# carries. A shared check prints its own refusal.
read_tag_documents() {
  rc_check_trust "${TAG}" "${TAG_TRUST}" || exit 1
  name_documents
}

# Prints the trust documents a release of this tag carries, as a message names them.
shown_documents() {
  case "${#DOCUMENTS[@]}" in
    0) echo "no trust document" ;;
    1) echo "trust-2.json" ;;
    *) echo "trust-2.json to trust-${RC_TRUST_N}.json" ;;
  esac
}

# Prints "<id> <true|false> <true|false>", the id of the one release that carries the tag
# $1, whether it is a draft and whether it is marked a pre-release, or nothing when there is
# none. The list holds drafts, which a lookup by tag does not, and two drafts can carry one
# tag.
find_release() {
  local found
  found="$(gh api --paginate "repos/${RELEASE_SLUG}/releases?per_page=100" \
    --jq '.[] | select(.tag_name == "'"$1"'") | "\(.id) \(.draft) \(.prerelease)"' | tr -d '\r')" \
    || setup_error "could not list the repository's releases."
  if [[ "$(printf '%s\n' "${found}" | grep -c .)" -gt 1 ]]; then
    refuse "more than one release carries the tag $1. Delete the extra drafts on GitHub."
  fi
  printf '%s\n' "${found}"
}

# Prints the asset names of the release with id $1, byte-sorted. It fails when GitHub does
# not answer, which the caller reports.
asset_names() {
  gh api "repos/${RELEASE_SLUG}/releases/$1/assets?per_page=100" --jq '.[].name' \
    | tr -d '\r' | LC_ALL=C sort
}

# Refuses a draft marked a pre-release ($1 is "true"): every check here is for a release
# that becomes the latest one, and read_latest leaves pre-releases out of what it compares.
refuse_prerelease() {
  [[ "$1" != "true" ]] || refuse "the draft for ${TAG} is marked a pre-release; clear it on GitHub."
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
  gh release download "${tag}" --repo "${RELEASE_SLUG}" --dir "${folder}" "${patterns[@]}" > /dev/null \
    || setup_error "could not download $* from the release ${tag}."
}

# Refuses unless each trust document in the folder $1, downloaded back from the release, is
# the tag's, byte for byte.
require_tag_documents() {
  local name
  for name in ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}; do
    cmp -s "$1/${name}" "${TAG_TRUST}/${name}" \
      || refuse "the release's ${name} is not ${TAG}'s trust/${name}. Delete the draft and run draft again."
  done
}

# Sets LATEST_TAG to the tag of the repository's latest release and LATEST_DOCUMENTS to the
# names of the trust documents it carries, both empty while no release is published. The
# list is read first because asking for the latest of none is an error like any other.
read_latest() {
  local published lines
  LATEST_TAG=""
  LATEST_DOCUMENTS=""
  published="$(gh api --paginate "repos/${RELEASE_SLUG}/releases?per_page=100" \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' | tr -d '\r')" \
    || setup_error "could not list the repository's releases."
  [[ -n "${published}" ]] || return 0
  lines="$(gh api "repos/${RELEASE_SLUG}/releases/latest" --jq '.tag_name, .assets[].name' | tr -d '\r')" \
    || setup_error "could not read the repository's latest release."
  LATEST_TAG="$(printf '%s\n' "${lines}" | head -1)"
  [[ -n "${LATEST_TAG}" ]] || setup_error "the repository's latest release names no tag."
  LATEST_DOCUMENTS="$(printf '%s\n' "${lines}" | tail -n +2 | grep -E "${TRUST_DOCUMENT_NAME}" || true)"
}

# Refuses when the latest release carries a trust document that the folder $1, the draft's
# assets, lacks or holds with other bytes. Clients read the chain from the newest release
# alone, so a release that dropped or changed a document would take it from all of them.
# Needs read_latest.
require_no_regress() {
  local back="$1" name
  [[ -n "${LATEST_DOCUMENTS}" ]] || return 0
  local latest="${SCRATCH}/latest" names=()
  while IFS= read -r name; do
    names+=("${name}")
  done <<< "${LATEST_DOCUMENTS}"
  download_assets "${LATEST_TAG}" "${latest}" "${names[@]}"
  for name in "${names[@]}"; do
    [[ -f "${back}/${name}" ]] && cmp -s "${back}/${name}" "${latest}/${name}" \
      || refuse "the latest release ${LATEST_TAG} carries ${name}, and the draft for ${TAG} does not carry the same bytes. A release never drops or changes a trust document."
  done
}

# Whether the version $1 is below the version $2, each three numbers. The numbers are
# compared by their digits, the longer being the greater once leading zeros are gone, as
# scripts/sign-release.sh's is_lower_release compares them: arithmetic would overflow on a
# long one and read it as a small one.
version_below() {
  local -a lower higher
  local i a b
  IFS=. read -r -a lower <<< "$1"
  IFS=. read -r -a higher <<< "$2"
  for i in 0 1 2; do
    a="${lower[i]#"${lower[i]%%[!0]*}"}"
    b="${higher[i]#"${higher[i]%%[!0]*}"}"
    if (( ${#a} < ${#b} )); then return 0; fi
    if (( ${#a} > ${#b} )); then return 1; fi
    if [[ "${a}" < "${b}" ]]; then return 0; fi
    if [[ "${a}" > "${b}" ]]; then return 1; fi
  done
  return 1
}

# Refuses unless the latest release is a version below this tag's: publishing makes this one
# the latest, and an update check must never be handed an older version. A repository with
# no latest release is refused too: an answer that hid the releases would read the same, so
# a repository's first release is published by hand. Needs read_latest.
require_latest_is_lower() {
  [[ -n "${LATEST_TAG}" ]] \
    || refuse "${RELEASE_SLUG} shows no published release, and ${TAG} is published only over a lower version."
  [[ "${LATEST_TAG}" =~ ${RC_RELEASE_TAG} ]] \
    || refuse "the latest release is ${LATEST_TAG}, which is not a version. Repair it with gh release edit v<the last version> --latest."
  version_below "${LATEST_TAG#v}" "${VERSION}" \
    || refuse "the latest release is ${LATEST_TAG}, which is not below ${TAG}."
}

# Prints the tag an anonymous reader gets as the repository's latest release. No token goes
# with the request: this is what the toolkit's update check sees.
anonymous_latest() {
  curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${RELEASE_SLUG}/releases/latest" 2>/dev/null \
    | tr -d '\r' | sed -nE 's/.*"tag_name": *"([^"]*)".*/\1/p' | head -1
}

# Succeeds once the anonymous latest release is the tag $1, and leaves the last tag read in
# LATEST_SEEN.
wait_for_latest() {
  local try
  for (( try = 1; try <= LATEST_TRIES; try++ )); do
    LATEST_SEEN="$(anonymous_latest || true)"
    [[ "${LATEST_SEEN}" == "$1" ]] && return 0
    (( try < LATEST_TRIES )) && sleep "${LATEST_PAUSE_SECONDS}"
  done
  return 1
}

check() {
  local branches run found
  branches="$(gh api "repos/${RELEASE_SLUG}/git/matching-refs/heads/${TAG}" \
    --jq '.[] | select(.ref == "refs/heads/'"${TAG}"'") | .ref' | tr -d '\r')" \
    || setup_error "could not read the repository's branches."
  # A run is matched by the name of its ref, which a branch named like the tag would share,
  # and a branch run skips the workflow's tag-only checks.
  [[ -z "${branches}" ]] || refuse "the repository has a branch named ${TAG}, so a run on the tag cannot be told from one on the branch."
  run="$(gh run list --repo "${RELEASE_SLUG}" --workflow release.yml --commit "${COMMIT}" --branch "${TAG}" \
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
  gh run download "${run}" --repo "${RELEASE_SLUG}" --name "release-${TAG}" --dir "${incoming}" \
    || refuse "run ${run} has no artifact named release-${TAG}."
  local held
  held="$(cd "${incoming}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
  [[ "${held}" == "$(sorted_names "${ZIP_NAME}" "${MANIFEST_NAME}")" ]] \
    || refuse "the artifact release-${TAG} must hold ${ZIP_NAME} and ${MANIFEST_NAME} only; it holds: $(shown "${held}")"

  rc_check_zip "${TAG}" "${incoming}/${ZIP_NAME}" || exit 1
  rc_expected_manifest "${TAG}" "${incoming}/${ZIP_NAME}" "${SCRATCH}/expected.update.json" || exit 1
  if ! cmp -s "${SCRATCH}/expected.update.json" "${incoming}/${MANIFEST_NAME}"; then
    echo "  this machine writes: $(shown_file "${SCRATCH}/expected.update.json")" >&2
    echo "  the run built:       $(shown_file "${incoming}/${MANIFEST_NAME}")" >&2
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
  local found root="${PUBLISH_RELEASE_HANDOFF_ROOT:-/Users/Shared}"
  found="$(find_release "${TAG}")"
  [[ -z "${found}" ]] || refuse "a release for ${TAG} is already on GitHub. To start over, delete the draft there."
  [[ -d "${root}" ]] || setup_error "no folder ${root} to leave the zip in; PUBLISH_RELEASE_HANDOFF_ROOT names another root."
  # No release carries the tag, so a folder of this account for it is left from a draft
  # that is gone, and the signing account could sign the zip in it. Another account's
  # folder is passed by: anyone can make one there, and it must not block a release.
  local earlier
  for earlier in "${root}/publish-release-${TAG}".*; do
    # -O is false for the pattern itself, which the loop gets when nothing matches.
    if [[ -O "${earlier}" ]]; then
      refuse "an earlier hand-off folder for ${TAG} is still there: $(shown "${earlier}"). Remove it, then run draft again."
    fi
  done
  make_scratch
  read_tag_documents

  # The signing account is another user, and it reads the zip here: a new folder each time,
  # so nothing that was waiting at a known path is ever handed over. It is made before the
  # draft, which no later run of this step could add it to, and removed again by clean_up
  # when this run ends without the draft.
  local handoff
  handoff="$(mktemp -d "${root}/publish-release-${TAG}.XXXXXX")" || setup_error "could not make a folder under ${root}."
  UNFINISHED_HANDOFF="${handoff}"
  cp "${WORK}/${ZIP_NAME}" "${handoff}/${ZIP_NAME}"
  chmod 755 "${handoff}"
  chmod 644 "${handoff}/${ZIP_NAME}"

  local files=("${WORK}/${ZIP_NAME}" "${WORK}/${MANIFEST_NAME}") name
  for name in ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}; do
    files+=("${TAG_TRUST}/${name}")
  done
  # --verify-tag stops gh from creating the tag when the remote has none.
  gh release create "${TAG}" --repo "${RELEASE_SLUG}" --draft --verify-tag --title "${TAG}" --notes "" "${files[@]}" \
    || setup_error "could not create the draft for ${TAG}."
  UNFINISHED_HANDOFF=""
  echo "Drafted ${TAG} with ${ZIP_NAME}, ${MANIFEST_NAME} and $(shown_documents)."
  echo "Next, the maintainer signs, in the signing account: scripts/sign-release.sh ${TAG} ${handoff}/${ZIP_NAME} <private-key.pem>"
  echo "Then: scripts/publish-release.sh attach ${TAG}"
}

# Prints the one folder the sign left for this tag under the root scripts/sign-release.sh
# writes to, and refuses when there is none or more than one: a guess between two could
# attach the wrong signature.
find_signed_folder() {
  local root="${SIGN_RELEASE_OUT_ROOT:-/Users/Shared}" folder suffix found=()
  for folder in "${root}/sign-release-${TAG}".*; do
    # The sign's mktemp ends the name in letters and digits. Any other name is not the
    # sign's, and one holding a line break or a control byte would be printed below.
    suffix="${folder#"${root}/sign-release-${TAG}."}"
    [[ "${suffix}" =~ ^[A-Za-z0-9]+$ && -d "${folder}" && ! -L "${folder}" ]] && found+=("${folder}")
  done
  case "${#found[@]}" in
    0) refuse "no folder named sign-release-${TAG}.* under ${root}. Run the sign command draft printed, or name the OUT folder it prints." ;;
    1) printf '%s\n' "${found[0]}" ;;
    *) refuse "more than one folder named sign-release-${TAG}.* under ${root}: ${found[*]}. Name the one the sign printed as OUT." ;;
  esac
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
## Asks the toolkit in this project whether it trusts a release, as a fresh install and as
## an install that starts from the first trust document.
##
## A fresh install holds the trust document this toolkit embeds and an empty store. An older
## install holds an earlier document and takes each later one from the release, so the walk
## starts from the first document with an empty store of its own and takes the release's
## documents in order.
## [codeblock]
## godot --headless --path <project> --script <this file> -- <manifest> <signature> \
##         <empty-folder> <trust-1.json> <another-empty-folder> [<trust-2.json> ...]
## [/codeblock]
## The engine prints its own lines around the verdict, and its exit code is unreliable on
## Windows, so the verdict is the line that starts with [constant RESULT_MARKER].

const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")

## Prefix of the output line that carries the verdict.
const RESULT_MARKER := "READER_CHECK_RESULT "

## The verdict on a release that both readers trust.
const TRUSTED := "trusted"

const _FIXED_ARGUMENTS := 5


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < _FIXED_ARGUMENTS:
		print(RESULT_MARKER + "wrong arguments")
		quit(2)
		return
	var verdict := _verdict(arguments)
	print(RESULT_MARKER + verdict)
	quit(0 if verdict == TRUSTED else 1)


func _verdict(arguments: PackedStringArray) -> String:
	var manifest := FileAccess.get_file_as_bytes(arguments[0])
	var signature := FileAccess.get_file_as_bytes(arguments[1])
	var fresh_install := {"trust_store": arguments[2]}
	if not ReleaseSignature.is_trusted(manifest, signature, null, fresh_install):
		return "not trusted"
	# A reader that trusted everything would pass the line above, so the same signature
	# over a changed manifest must be refused.
	var changed := manifest.duplicate()
	if not changed.is_empty():
		changed[0] = changed[0] ^ 1
	if ReleaseSignature.is_trusted(changed, signature, null, fresh_install):
		return "trusts a changed manifest"

	var first_document := FileAccess.get_file_as_string(arguments[3])
	var chain := TrustChain.new(first_document, arguments[4])
	if chain.version() != 1:
		return "the first trust document does not read as document 1"
	for index: int in range(_FIXED_ARGUMENTS, arguments.size()):
		var outcome := chain.accept(FileAccess.get_file_as_bytes(arguments[index]))
		if str(outcome["outcome"]) != TrustChain.ACCEPTED:
			return "the walk refuses %s: %s" % [arguments[index].get_file(), str(outcome["reason"])]
	var walked := {"trust_document": first_document, "trust_store": arguments[4]}
	if not ReleaseSignature.is_trusted(manifest, signature, null, walked):
		return "not trusted after the walk"
	return TRUSTED
GDSCRIPT
}

# Refuses unless the toolkit inside the draft's zip, run by the Godot binary $1 of version
# $2, trusts the draft's manifest and signature, both as a fresh install and after a walk
# from the tag's first trust document through the draft's own. $3 is the folder the draft's
# assets were downloaded back into.
reader_check() {
  local godot="$1" minor="$2" back="$3"
  local root="${SCRATCH}/reader-${minor}" output name
  local project="${root}/project" documents=()
  mkdir -p "${project}" "${root}/store" "${root}/walk-store"
  unzip -q "${back}/${ZIP_NAME}" -d "${project}"
  printf 'config_version=5\n\n[application]\n\nconfig/name="Release reader check"\n' > "${project}/project.godot"
  write_reader_script "${project}/reader_check.gd"
  for name in ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}; do
    documents+=("${back}/${name}")
  done
  output="$("$(ut_timeout_bin)" "${READER_SECONDS}" "${godot}" --headless --path "${project}" \
    --script "${project}/reader_check.gd" -- "${back}/${MANIFEST_NAME}" "${back}/${SIGNATURE_NAME}" "${root}/store" \
    "${TAG_TRUST}/trust-1.json" "${root}/walk-store" ${documents[@]+"${documents[@]}"} 2>&1 | tr -d '\r')" || true
  if ! grep -qxF "${READER_MARKER}trusted" <<< "${output}"; then
    printf '%s\n' "${output}" | rc_printable | sed 's/^/  /' >&2
    refuse "on Godot ${minor}, the toolkit in the draft's zip does not trust the draft's manifest and signature, or does not walk to its trust documents."
  fi
  echo "  Godot ${minor}: the toolkit in the draft's zip trusts the draft, as a fresh install and after a walk from trust-1.json through $(shown_documents)"
}

attach() {
  local folder="${1:-}" name
  require_checked
  # A refusal inside the substitution ends only its subshell, so the status is passed on.
  [[ -n "${folder}" ]] || folder="$(find_signed_folder)" || exit 1
  [[ -d "${folder}" ]] \
    || refuse "no folder at ${folder}. It is the OUT folder scripts/sign-release.sh prints."
  for name in "${MANIFEST_NAME}" "${SIGNATURE_NAME}"; do
    [[ -f "${folder}/${name}" && ! -L "${folder}/${name}" ]] \
      || refuse "${folder} holds no ${name}. It is the OUT folder scripts/sign-release.sh prints."
  done
  # The sign writes its own manifest from the tag and the zip it was handed, so a difference
  # means the two accounts did not look at the same release.
  if ! cmp -s "${folder}/${MANIFEST_NAME}" "${WORK}/${MANIFEST_NAME}"; then
    echo "  check passed: $(shown_file "${WORK}/${MANIFEST_NAME}")" >&2
    echo "  the sign wrote: $(shown_file "${folder}/${MANIFEST_NAME}")" >&2
    refuse "the manifest in ${folder} is not the one check passed for ${TAG}. Nothing is uploaded."
  fi
  local signature="${WORK}/${SIGNATURE_NAME}"
  cp "${folder}/${SIGNATURE_NAME}" "${signature}"
  bash "${REPO_ROOT}/scripts/sign-release.sh" --verify "${WORK}/${MANIFEST_NAME}" \
    || refuse "scripts/sign-release.sh --verify does not accept the signature in ${folder}."
  # Every tool the reader check needs is looked for here, before the upload.
  command -v unzip >/dev/null 2>&1 || setup_error "unzip is required."
  command -v "$(ut_timeout_bin)" >/dev/null 2>&1 || setup_error "$(ut_timeout_bin) is required."
  local minor binaries=()
  for minor in ${READER_MINORS}; do
    binaries+=("$(godot_for "${minor}")")
  done

  local found id is_draft is_prerelease
  found="$(find_release "${TAG}")"
  [[ -n "${found}" ]] || refuse "${TAG} has no draft: run scripts/publish-release.sh draft ${TAG} first."
  read -r id is_draft is_prerelease <<< "${found}"
  [[ "${is_draft}" == "true" ]] || refuse "${TAG} is already published."
  refuse_prerelease "${is_prerelease}"
  make_scratch
  read_tag_documents
  local names unsigned signed
  names="$(asset_names "${id}")" || setup_error "could not read the assets of the draft for ${TAG}."
  unsigned="$(sorted_names "${ZIP_NAME}" "${MANIFEST_NAME}" ${DOCUMENTS[@]+"${DOCUMENTS[@]}"})"
  signed="$(sorted_names "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}" ${DOCUMENTS[@]+"${DOCUMENTS[@]}"})"
  [[ "${names}" == "${unsigned}" || "${names}" == "${signed}" ]] \
    || refuse "the draft for ${TAG} must hold the zip, the manifest, $(shown_documents) and at most the signature; it holds: ${names//$'\n'/, }"

  local back="${SCRATCH}/draft"
  # Nothing is added to a draft that does not hold the files check passed and the tag's
  # trust documents.
  download_assets "${TAG}" "${back}" "${ZIP_NAME}" "${MANIFEST_NAME}" ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}
  cmp -s "${back}/${ZIP_NAME}" "${WORK}/${ZIP_NAME}" && cmp -s "${back}/${MANIFEST_NAME}" "${WORK}/${MANIFEST_NAME}" \
    || refuse "the draft for ${TAG} does not hold the zip and manifest that were checked. Delete the draft and run draft again."
  require_tag_documents "${back}"
  read_latest
  require_no_regress "${back}"
  if [[ "${names}" == "${unsigned}" ]]; then
    gh release upload "${TAG}" "${signature}" --repo "${RELEASE_SLUG}" || setup_error "could not upload ${SIGNATURE_NAME}."
  fi
  download_assets "${TAG}" "${back}" "${SIGNATURE_NAME}"
  cmp -s "${back}/${SIGNATURE_NAME}" "${signature}" \
    || refuse "the draft's ${SIGNATURE_NAME} is not the one in ${folder}. Delete that asset from the draft and run attach again."

  # An earlier pass says nothing about this run's bytes.
  rm -f "${READER_CHECKED}"
  echo "The reader check, on the bytes downloaded back from the draft:"
  local index=0
  for minor in ${READER_MINORS}; do
    reader_check "${binaries[${index}]}" "${minor}" "${back}"
    index=$((index + 1))
  done
  printf 'release %s\nzip %s\nmanifest %s\nsignature %s\n' "${id}" "$(rf_sha256 "${back}/${ZIP_NAME}")" \
    "$(rf_sha256 "${back}/${MANIFEST_NAME}")" "$(rf_sha256 "${back}/${SIGNATURE_NAME}")" > "${READER_CHECKED}"
  echo "Attached ${SIGNATURE_NAME} to the draft for ${TAG}."
  echo "Next, the maintainer publishes: scripts/publish-release.sh publish ${TAG}"
}

# Everything publish holds a release to, from the bytes downloaded back into the folder $1.
# The local records play no part: the zip is checked against the tag, the manifest against
# the one this machine writes for that zip, the signature against the tag's release keys and
# the trust documents against the tag's.
require_assets_are_the_tag() {
  local back="$1"
  rc_check_zip "${TAG}" "${back}/${ZIP_NAME}" || exit 1
  rc_expected_manifest "${TAG}" "${back}/${ZIP_NAME}" "${SCRATCH}/expected.update.json" || exit 1
  if ! cmp -s "${SCRATCH}/expected.update.json" "${back}/${MANIFEST_NAME}"; then
    echo "  this machine writes: $(shown_file "${SCRATCH}/expected.update.json")" >&2
    echo "  the release holds:   $(shown_file "${back}/${MANIFEST_NAME}")" >&2
    refuse "the release's ${MANIFEST_NAME} is not the manifest of its zip at ${TAG}."
  fi
  bash "${REPO_ROOT}/scripts/sign-release.sh" --verify "${back}/${MANIFEST_NAME}" \
    || refuse "scripts/sign-release.sh --verify does not accept the release's ${SIGNATURE_NAME}."
  require_tag_documents "${back}"
}

# The checks on a published release: $1 is its id, $2 the folder its assets were downloaded
# back into and $3 the asset names it must hold. With immutable releases on it is final, and
# a failed line is fixed by a new release, so every line runs before the verdict.
check_published() {
  local id="$1" back="$2" expected="$3" failed=0 immutable file name names
  local files=("${back}/${ZIP_NAME}" "${back}/${MANIFEST_NAME}" "${back}/${SIGNATURE_NAME}")
  for name in ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}; do
    files+=("${back}/${name}")
  done
  gh release verify "${TAG}" --repo "${RELEASE_SLUG}" || { echo "  FAIL: gh release verify ${TAG}" >&2; failed=1; }
  for file in "${files[@]}"; do
    gh release verify-asset "${TAG}" "${file}" --repo "${RELEASE_SLUG}" \
      || { echo "  FAIL: gh release verify-asset ${TAG} $(basename "${file}")" >&2; failed=1; }
  done
  # An asset added between publish's last read of the draft and the publish is seen here.
  names="$(asset_names "${id}" || true)"
  [[ "${names}" == "${expected}" ]] \
    || { echo "  FAIL: the release must hold the zip, the manifest, the signature and $(shown_documents), and nothing else; it holds: $(shown "${names:-unread}")" >&2; failed=1; }
  immutable="$(gh api "repos/${RELEASE_SLUG}/releases/${id}" --jq .immutable | tr -d '\r' || true)"
  [[ "${immutable}" == "true" ]] || { echo "  FAIL: the release is not immutable (immutable: ${immutable:-unread})" >&2; failed=1; }
  wait_for_latest "${TAG}" \
    || { echo "  FAIL: an anonymous reader's latest release is '${LATEST_SEEN}', not ${TAG}" >&2; failed=1; }
  if [[ "${failed}" -ne 0 ]]; then
    echo "error: ${TAG} is published, and a check on it failed. It cannot be withdrawn: fix forward." >&2
    exit 1
  fi
  echo "${TAG} is published, attested, immutable and the latest release."
  echo "Next, the ledger: add this line to trust/released-manifests.txt through a pull request from chore/ledger-${VERSION}:"
  echo "  ${VERSION} $(rf_sha256 "${back}/${MANIFEST_NAME}")"
}

publish() {
  # The tools the checks below run, looked for before anything is read, as check does.
  [[ -f scripts/check-release-zip.mjs ]] || setup_error "scripts/check-release-zip.mjs is missing."
  command -v node >/dev/null 2>&1 || setup_error "node is required."
  make_scratch
  rc_checks_1_to_6 "${TAG}" "${TAG_TRUST}" || exit 1
  name_documents
  require_checked
  [[ -f "${READER_CHECKED}" ]] \
    || refuse "the reader check has not passed for ${TAG}: run scripts/publish-release.sh attach first."
  local found id is_draft is_prerelease names expected
  found="$(find_release "${TAG}")"
  [[ -n "${found}" ]] || refuse "${TAG} has no draft: run draft, the sign command and attach first."
  read -r id is_draft is_prerelease <<< "${found}"
  [[ "${is_draft}" != "true" ]] || refuse_prerelease "${is_prerelease}"
  [[ "${id}" == "$(record_value "${READER_CHECKED}" release)" ]] \
    || refuse "the release for ${TAG} is not the draft the reader check passed for. Run attach again."
  expected="$(sorted_names "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}" ${DOCUMENTS[@]+"${DOCUMENTS[@]}"})"
  names="$(asset_names "${id}")" || setup_error "could not read the assets of the release for ${TAG}."
  [[ "${names}" == "${expected}" ]] \
    || refuse "the release for ${TAG} must hold the zip, the manifest, the signature and $(shown_documents), and nothing else."

  local back="${SCRATCH}/release" name file
  download_assets "${TAG}" "${back}" "${ZIP_NAME}" "${MANIFEST_NAME}" "${SIGNATURE_NAME}" ${DOCUMENTS[@]+"${DOCUMENTS[@]}"}
  require_assets_are_the_tag "${back}"
  for name in zip manifest signature; do
    case "${name}" in
      zip) file="${ZIP_NAME}" ;;
      manifest) file="${MANIFEST_NAME}" ;;
      *) file="${SIGNATURE_NAME}" ;;
    esac
    [[ "$(rf_sha256 "${back}/${file}")" == "$(record_value "${READER_CHECKED}" "${name}")" ]] \
      || refuse "the release's ${file} is not the one the reader check passed for. Run attach again."
  done

  if [[ "${is_draft}" == "true" ]]; then
    read_latest
    require_no_regress "${back}"
    local immutable again again_names
    immutable="$(gh api "repos/${RELEASE_SLUG}/immutable-releases" --jq .enabled | tr -d '\r')" \
      || setup_error "could not read whether immutable releases are on for ${RELEASE_SLUG}."
    [[ "${immutable}" == "true" ]] \
      || refuse "immutable releases are not on for ${RELEASE_SLUG} (enabled: $(shown "${immutable:-unread}")), so a published release could still be changed."
    require_latest_is_lower
    # The checks above took time, and the draft could be changed meanwhile. GitHub has no
    # call that checks and publishes as one step, so the draft is read once more here, and
    # check_published reads the asset names a last time after the publish.
    again="$(find_release "${TAG}")"
    again_names="$(asset_names "${id}")" || setup_error "could not read the assets of the release for ${TAG}."
    [[ "${again}" == "${found}" && "${again_names}" == "${names}" ]] \
      || refuse "the draft for ${TAG} changed while it was being checked. Nothing is published: look at the draft on GitHub, then run publish again."
    gh release edit "${TAG}" --repo "${RELEASE_SLUG}" --draft=false --latest || setup_error "could not publish ${TAG}."
    echo "Published ${TAG}."
  else
    # A run that stopped after the publish can be run again for the checks that follow it.
    echo "${TAG} is already published; checking it again."
  fi
  check_published "${id}" "${back}" "${expected}"
}

case "${1:-}" in
  -h | --help | "")
    usage
    exit 0
    ;;
  check | draft | publish)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    require_pinned_repository
    use_tag "$2"
    "$1"
    ;;
  attach)
    [[ $# -eq 2 || $# -eq 3 ]] || { usage >&2; exit 2; }
    require_pinned_repository
    use_tag "$2"
    attach "${3:-}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
