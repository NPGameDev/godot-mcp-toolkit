#!/usr/bin/env bash
# Sign, or verify, a release's update manifest.
#
# A release's update manifest (godot-mcp-toolkit-<version>.update.json) is signed with RSA
# and SHA-256 over its exact bytes, trailing newline included. The signature is
# godot-mcp-toolkit-<version>.update.json.sig, a fixed asset name. The release's tag is
# v<version>, and the keys a signature may come from are the release keys of the highest
# trust/trust-N.json at that tag. They are read from the checkout this script sits in, and
# only after the tag's trust documents pass rc_check_trust (scripts/lib/release_checks.sh).
#
# Usage:
#   scripts/sign-release.sh <tag> <zip> <private-key.pem>
#       sign the manifest of <zip> at <tag>, from a fresh clone of the repository's main
#       branch. It copies <zip> first and reads nothing else it is handed but the key. It
#       refuses, in this order, when: GH_REPO, GH_HOST, GIT_DIR, GIT_WORK_TREE or
#       NODE_OPTIONS is set; origin is not the URL pinned in
#       scripts/lib/release_identity.sh; the checkout has changes or is not at the tip of
#       origin's main; origin's <tag> is not this checkout's; the tag's commit is not on
#       origin's main; the tag's trust documents are not the pinned first one and a chain
#       that verifies, or the toolkit at the tag does not hold the last; or
#       scripts/check-release-zip.mjs does not accept the copy for the tag. It then writes
#       the manifest itself, from the copy and the tag, and shows the tag, its commit and
#       what changed since the release before. Type the first 8 hex digits of the commit
#       as github.com shows them: anything else is refused. It asks for the key's
#       passphrase, signs, and keeps the signature only if a release key of the tag's
#       highest trust document verifies it. A non-RSA key is refused.
#       The manifest and its .sig go to a new folder under /Users/Shared, readable from
#       every account; SIGN_RELEASE_OUT_ROOT names another parent folder. The last line
#       printed is "OUT <folder>". A refusal leaves no folder.
#       With stdin a pipe, its one line is the passphrase, and the 8 hex digits are read
#       from file descriptor 3 if it is open, else from the terminal.
#   scripts/sign-release.sh --verify <manifest>
#       check the .sig beside <manifest> against each release key of the highest trust
#       document at the tag v<the manifest's version>; one that verifies is enough. The
#       tag's trust documents must pass the same check as for signing.
#
# Exit 0 = signed or verified, 1 = refused, 2 = wrong usage, or a missing tool or folder
# to leave the signature in.
#
# Make a key once, an encrypted RSA-2048 PEM (where the private half is kept is the
# maintainer's choice). Its public half becomes a release key through
# scripts/trust-document.sh build --add-release:
#   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -out release-signing.pem
#   openssl pkey -in release-signing.pem -pubout -out release-signing.pub.pem
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_checks.sh
source "${REPO_ROOT}/scripts/lib/release_checks.sh"

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show' "$0" | sed 's/^# \{0,1\}//'
}

refuse() {
  echo "refused: $*" >&2
  exit 1
}

# Prints the manifest's version. It becomes part of a path and of a tag's name, so
# anything but a version is refused.
manifest_version() {
  local version
  version="$(sed -nE 's/.*"version": *"([^"]*)".*/\1/p' "$1" | tr -d '\r')"
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo "refused: $1 carries no usable version." >&2
    return 1
  fi
  printf '%s\n' "${version}"
}

# Reads the release keys of the tag's highest trust document, which rc_check_trust left
# in ${WORK}/trust: each goes to ${WORK}/release.<n>.pem, counted from 1. Sets
# TRUST_DOCUMENT to the document's name and RELEASE_KEY_COUNT to how many keys it lists.
# The tag decides, not the files checked out, so an older release still verifies against
# the keys it shipped with.
read_release_keys() {
  local tag="$1" line
  TRUST_DOCUMENT="trust-${RC_TRUST_N}.json"
  bash "${REPO_ROOT}/scripts/trust-document.sh" release-keys "${WORK}/trust/${TRUST_DOCUMENT}" \
    > "${WORK}/release-keys.pem" < /dev/null \
    || refuse "could not read the release keys of ${TRUST_DOCUMENT} at ${tag}."
  RELEASE_KEY_COUNT=0
  while IFS= read -r line; do
    [[ "${line}" != "-----BEGIN PUBLIC KEY-----" ]] || RELEASE_KEY_COUNT=$((RELEASE_KEY_COUNT + 1))
    printf '%s\n' "${line}" >> "${WORK}/release.${RELEASE_KEY_COUNT}.pem"
  done < "${WORK}/release-keys.pem"
}

# Whether the signature in the file $2, over the manifest $1, verifies under one of the
# release keys read_release_keys read.
verifies_under_a_release_key() {
  local i
  for (( i = 1; i <= RELEASE_KEY_COUNT; i++ )); do
    if openssl dgst -sha256 -verify "${WORK}/release.${i}.pem" -signature "$2" "$1" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# Drops the control characters of the text on stdin but the tab and the line break, so a
# commit's subject or a file's name cannot drive the terminal it is shown on.
printable() {
  tr -d '\000-\010\013-\037\177'
}

# Whether the release tag $1 is a lower version than the release tag $2. The three numbers
# are compared by their digits, the longer being the greater once leading zeros are gone:
# arithmetic would overflow on a long one.
is_lower_release() {
  local -a lower higher
  local i a b
  IFS=. read -r -a lower <<< "${1#v}"
  IFS=. read -r -a higher <<< "${2#v}"
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

# Shows what signing the tag $1 would release, then takes the first 8 hex digits of its
# commit from the maintainer, who reads them on github.com. This checkout and origin
# already agree on the tag; the typed digits tie both to what the website shows a person.
# Needs rc_check_tag.
confirm_commit() {
  local tag="$1" name previous="" base range since count typed=""
  # The release before is the highest release tag the commit reaches whose version is
  # lower than this tag's. A tag of a higher version can sit on the same commit or on an
  # earlier one, and is no release before this one.
  while IFS= read -r name; do
    [[ "${name}" =~ ${RC_RELEASE_TAG} ]] || continue
    is_lower_release "${name}" "${tag}" || continue
    if [[ -z "${previous}" ]] || is_lower_release "${previous}" "${name}"; then
      previous="${name}"
    fi
  done < <(git -C "${REPO_ROOT}" tag --merged "${RC_COMMIT}" | tr -d '\r')
  if [[ -n "${previous}" ]]; then
    base="refs/tags/${previous}"
    range="${base}..${RC_COMMIT}"
    since="since ${previous}"
  else
    # No release before this one: everything the commit holds is new, so the comparison
    # is with the empty tree.
    base="$(git -C "${REPO_ROOT}" hash-object -t tree --stdin < /dev/null | tr -d '\r')"
    range="${RC_COMMIT}"
    since="with no release tag before it"
  fi
  count="$(git -C "${REPO_ROOT}" rev-list --count "${range}" | tr -d '\r')" \
    || refuse "could not read the history of ${tag}."
  echo "Tag      ${tag}"
  echo "Commit   ${RC_COMMIT}"
  echo "Subject  $(git --no-pager -C "${REPO_ROOT}" log -1 --no-color --format=%s "${RC_COMMIT}" | printable)"
  echo "Commits ${since} (${count}):"
  git --no-pager -C "${REPO_ROOT}" log --no-color --format='  %h %s' "${range}" | printable \
    || refuse "could not read the history of ${tag}."
  echo "Changes under scripts/ and trust/ ${since}:"
  git --no-pager -C "${REPO_ROOT}" diff --no-color --no-ext-diff --stat "${base}" "${RC_COMMIT}" -- scripts/ trust/ | printable \
    || refuse "could not compare ${tag} with the release before it."

  local prompt="First 8 hex digits of the commit of ${tag}, as github.com shows them: "
  if [[ -t 0 ]]; then
    IFS= read -r -p "${prompt}" typed || true
  elif { true <&3; } 2>/dev/null; then
    IFS= read -r typed <&3 || true
  elif { true < /dev/tty; } 2>/dev/null; then
    printf '%s' "${prompt}" >&2
    IFS= read -r typed < /dev/tty || true
  else
    refuse "stdin is a pipe, and neither file descriptor 3 nor a terminal is there to read the commit's first 8 hex digits from."
  fi
  typed="${typed%$'\r'}"
  [[ "${typed}" == "${RC_COMMIT:0:8}" ]] \
    || refuse "what was typed is not the first 8 hex digits of the commit of ${tag}; nothing is signed."
}

verify_manifest() {
  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  local manifest="$1" version sig
  rc_check_environment || exit 1
  [[ -f "${manifest}" ]] || refuse "no manifest at ${manifest}."
  version="$(manifest_version "${manifest}")"
  sig="$(dirname "${manifest}")/godot-mcp-toolkit-${version}.update.json.sig"
  [[ -f "${sig}" ]] || refuse "no signature at ${sig}."
  rc_check_trust "v${version}" "${WORK}/trust" || exit 1
  read_release_keys "v${version}"
  verifies_under_a_release_key "${manifest}" "${sig}" \
    || refuse "${sig} verifies under none of the ${RELEASE_KEY_COUNT} release keys of ${TRUST_DOCUMENT} at v${version}."
  echo "${sig} verifies under a release key of ${TRUST_DOCUMENT} at v${version}."
}

sign_release() {
  [[ $# -eq 3 ]] || { usage >&2; exit 2; }
  local tag="$1" zip="$2" key="$3" out_root="${SIGN_RELEASE_OUT_ROOT:-/Users/Shared}"
  local version manifest_name zip_copy manifest passphrase="" out
  [[ "${tag}" =~ ${RC_RELEASE_TAG} ]] || refuse "${tag} is no release tag; one reads v<major>.<minor>.<patch>."
  [[ -f "${zip}" ]] || refuse "no zip at ${zip}."
  [[ -f "${key}" ]] || refuse "no key at ${key}."
  command -v node >/dev/null 2>&1 || { echo "error: node is required to sign." >&2; exit 2; }
  [[ -d "${out_root}" ]] \
    || { echo "error: no folder at ${out_root} to leave the signature in; SIGN_RELEASE_OUT_ROOT names another." >&2; exit 2; }

  # The zip arrives through a folder other accounts write to, so every check and the
  # manifest read this private copy. The copy's name is the release's own: the manifest
  # names its archive after the file it is written from.
  version="${tag#v}"
  manifest_name="godot-mcp-toolkit-${version}.update.json"
  zip_copy="${WORK}/godot-mcp-toolkit-${version}.zip"
  manifest="${WORK}/${manifest_name}"
  cp "${zip}" "${zip_copy}"

  rc_checks_1_to_6 "${tag}" "${WORK}/trust" || exit 1
  rc_check_zip "${tag}" "${zip_copy}" || exit 1
  rc_expected_manifest "${tag}" "${zip_copy}" "${manifest}" || exit 1
  read_release_keys "${tag}"
  (( RELEASE_KEY_COUNT > 0 )) || refuse "${TRUST_DOCUMENT} at ${tag} lists no release key, so no signature could verify."
  confirm_commit "${tag}"

  if [[ -t 0 ]]; then
    IFS= read -rs -p "Passphrase for ${key}: " passphrase
    echo >&2
  else
    IFS= read -r passphrase || true
  fi
  # This is the one read of the private key. An encrypted PEM does not say its key's type
  # before the passphrase opens it, so this same call refuses a non-RSA key: only an RSA
  # key takes this padding option, and a PSS key takes only PSS, so openssl stops before
  # it signs. openssl reads the passphrase line whether or not the key needs it.
  printf '%s\n' "${passphrase}" \
    | openssl dgst -sha256 -sign "${key}" -passin stdin -sigopt rsa_padding_mode:pkcs1 -out "${manifest}.sig" "${manifest}" \
    || refuse "could not sign with ${key}: the passphrase is wrong, or it is not an RSA key; a release's signature must be RSA."
  passphrase=""
  # Whether the key is a release key shows in its signature, with no second read of it.
  verifies_under_a_release_key "${manifest}" "${manifest}.sig" \
    || refuse "${key} is none of the ${RELEASE_KEY_COUNT} release keys of ${TRUST_DOCUMENT} at ${tag}; no .sig is written."

  # A new folder, never a path that was already there: other accounts write to the parent,
  # and a name they chose could lead anywhere. It opens to them only once it is complete.
  PENDING_OUT="$(mktemp -d "${out_root}/sign-release-${tag}.XXXXXX")" \
    || { echo "error: could not make a folder under ${out_root}." >&2; exit 2; }
  cp "${manifest}" "${manifest}.sig" "${PENDING_OUT}/"
  chmod 644 "${PENDING_OUT}/${manifest_name}" "${PENDING_OUT}/${manifest_name}.sig"
  chmod 755 "${PENDING_OUT}"
  out="${PENDING_OUT}"
  PENDING_OUT=""
  echo "Signed ${manifest_name} of ${tag}; the signature verifies under a release key of ${TRUST_DOCUMENT}."
  echo "Next, in the account that made the draft: scripts/publish-release.sh attach ${tag} ${out}"
  echo "OUT ${out}"
}

case "${1:-}" in
  -h|--help|"")
    usage
    exit 0
    ;;
esac

for tool in openssl git; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "error: ${tool} is required." >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sign-release.XXXXXX")"
PENDING_OUT=""
trap 'rm -rf "${WORK}"; [[ -z "${PENDING_OUT}" ]] || rm -rf "${PENDING_OUT}"' EXIT

case "$1" in
  --verify)
    shift
    verify_manifest "$@"
    ;;
  -*)
    usage >&2
    exit 2
    ;;
  *)
    sign_release "$@"
    ;;
esac
