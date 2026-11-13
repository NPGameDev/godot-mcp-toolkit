#!/usr/bin/env bash
# Sign, or verify, a release's update manifest.
#
# A release's update manifest (godot-mcp-toolkit-<version>.update.json, written by
# build-plugin-release.sh) is signed with RSA and SHA-256 over its exact bytes, trailing
# newline included. The signature sits beside the manifest as
# godot-mcp-toolkit-<version>.update.json.sig. That is a fixed asset name, so it comes
# from the manifest's version, never its path. The release's tag is v<version>, and the
# keys a signature may come from are the release keys of the newest trust/trust-N.json
# at that tag, read from the checkout this script sits in.
#
# Usage:
#   scripts/sign-release.sh <manifest> <private-key.pem>
#       write the .sig beside <manifest>. The draft release v<version> must already hold
#       the manifest: this prints the manifest's SHA-256 next to the digest GitHub
#       reports for the draft's copy, and signs only when the two match. It asks for the
#       key's passphrase, or reads it as one line from a pipe on stdin. A non-RSA key is
#       refused, and the .sig is kept only if --verify would accept it, so a key that is
#       no release key of the trust document at the tag leaves no .sig. It needs gh,
#       signed in to the repository; GH_BIN names another gh than the one on the PATH.
#   scripts/sign-release.sh --verify <manifest>
#       check the .sig beside <manifest> against each release key of the trust document
#       at the tag; one that verifies is enough
#
# Exit 0 = signed or verified, 1 = refused, 2 = wrong usage or a missing tool.
#
# Make a key once, an encrypted RSA-2048 PEM (where the private half is kept is the
# maintainer's choice). Its public half becomes a release key through
# scripts/trust-document.sh build --add-release:
#   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -out release-signing.pem
#   openssl pkey -in release-signing.pem -pubout -out release-signing.pub.pem
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

# GitHub fills an asset's digest at upload, and a read right after the upload can still
# find none.
DIGEST_READS=5
DIGEST_WAIT_SECONDS=3

# Nine digits fit bash's arithmetic on every build and outrun any real document number.
TRUST_DOCUMENT_PATH='^trust/trust-([1-9][0-9]{0,8})\.json$'
NEWLINE=$'\n'

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Prints the manifest's version. It becomes part of a path, so anything but a version
# is refused.
manifest_version() {
  local version
  version="$(sed -nE 's/.*"version": *"([^"]*)".*/\1/p' "$1" | tr -d '\r')"
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo "error: $1 carries no usable version." >&2
    return 1
  fi
  printf '%s\n' "${version}"
}

# Prints where the signature of the manifest $1, of version $2, belongs.
sig_path() {
  printf '%s/godot-mcp-toolkit-%s.update.json.sig\n' "$(dirname "$1")" "$2"
}

# Reads the release keys of the newest trust document at the tag of the version $1: each
# goes to ${WORK}/release.<n>.pem, counted from 1. Sets TRUST_DOCUMENT to the document's
# name and RELEASE_KEY_COUNT to how many keys it lists. The tag decides, not the files
# checked out, so an older release still verifies against the keys it shipped with.
read_release_keys() {
  local version="$1" tag="refs/tags/v$1" path line newest=0
  git -C "${REPO_ROOT}" rev-parse -q --verify "${tag}^{commit}" >/dev/null 2>&1 \
    || die "this checkout has no tag v${version}."
  while IFS= read -r path; do
    if [[ "${path}" =~ ${TRUST_DOCUMENT_PATH} ]] && (( BASH_REMATCH[1] > newest )); then
      newest="${BASH_REMATCH[1]}"
    fi
  done < <(git -C "${REPO_ROOT}" ls-tree --name-only "${tag}" trust/ | tr -d '\r')
  (( newest > 0 )) || die "the tag v${version} holds no trust document."
  TRUST_DOCUMENT="trust-${newest}.json"
  git -C "${REPO_ROOT}" show "${tag}:trust/${TRUST_DOCUMENT}" > "${WORK}/${TRUST_DOCUMENT}"
  bash "${REPO_ROOT}/scripts/trust-document.sh" release-keys "${WORK}/${TRUST_DOCUMENT}" > "${WORK}/release-keys.pem" \
    || die "could not read the release keys of ${TRUST_DOCUMENT} at v${version}."
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

# One read of the GitHub API, run from this checkout so gh fills in its repository. A
# passphrase may be waiting on stdin, so gh gets none of it.
github_read() {
  (cd "${REPO_ROOT}" && "${GH_BIN:-gh}" api "$@" < /dev/null) | tr -d '\r'
}

# Sets DRAFT_DIGEST to the digest GitHub reports, as sha256:<hex>, for the asset $2 of
# the draft release tagged for the version $1. GitHub lets several drafts carry one tag,
# and only one of them can be the release that publishes, so more than one is refused.
read_draft_digest() {
  local version="$1" asset="$2" ids reads
  ids="$(github_read "repos/{owner}/{repo}/releases" --paginate \
    --jq ".[] | select(.draft and .tag_name == \"v${version}\") | .id")" \
    || die "could not list the repository's releases; is gh signed in?"
  [[ -n "${ids}" ]] \
    || die "there is no draft release for v${version}; scripts/publish-release.sh draft v${version} makes it."
  [[ "${ids}" != *"${NEWLINE}"* ]] || die "more than one draft release is tagged v${version}."
  [[ "${ids}" =~ ^[0-9]+$ ]] || die "could not read the draft release's id for v${version}."
  DRAFT_DIGEST=""
  for (( reads = 1; reads <= DIGEST_READS; reads++ )); do
    DRAFT_DIGEST="$(github_read "repos/{owner}/{repo}/releases/${ids}/assets" \
      --jq ".[] | select(.name == \"${asset}\" and .digest != null) | .digest")" \
      || die "could not read the assets of the draft release for v${version}."
    [[ -z "${DRAFT_DIGEST}" ]] || return 0
    (( reads == DIGEST_READS )) || sleep "${DIGEST_WAIT_SECONDS}"
  done
  die "the draft release for v${version} reports no digest for ${asset}: the asset is not there, or GitHub has not filled its digest in."
}

verify_manifest() {
  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  local manifest="$1" version sig
  [[ -f "${manifest}" ]] || die "no manifest at ${manifest}."
  version="$(manifest_version "${manifest}")"
  sig="$(sig_path "${manifest}" "${version}")"
  [[ -f "${sig}" ]] || die "no signature at ${sig}."
  read_release_keys "${version}"
  verifies_under_a_release_key "${manifest}" "${sig}" \
    || die "${sig} verifies under none of the ${RELEASE_KEY_COUNT} release keys of ${TRUST_DOCUMENT} at v${version}."
  echo "${sig} verifies under a release key of ${TRUST_DOCUMENT} at v${version}."
}

sign_manifest() {
  [[ $# -eq 2 ]] || { usage >&2; exit 2; }
  local manifest="$1" key="$2" version sig asset local_digest passphrase=""
  [[ -f "${manifest}" ]] || die "no manifest at ${manifest}."
  [[ -f "${key}" ]] || die "no key at ${key}."
  command -v "${GH_BIN:-gh}" >/dev/null 2>&1 || { echo "error: gh is required to sign." >&2; exit 2; }
  version="$(manifest_version "${manifest}")"
  sig="$(sig_path "${manifest}" "${version}")"
  asset="godot-mcp-toolkit-${version}.update.json"
  read_release_keys "${version}"

  read_draft_digest "${version}" "${asset}"
  local_digest="sha256:$(rf_sha256 "${manifest}")"
  echo "${asset} of v${version}:"
  echo "  the manifest here       ${local_digest}"
  echo "  the draft's manifest    ${DRAFT_DIGEST}"
  [[ "${DRAFT_DIGEST}" == "${local_digest}" ]] \
    || die "the draft release for v${version} holds another manifest than ${manifest}; nothing is signed."

  if [[ -t 0 ]]; then
    IFS= read -rs -p "Passphrase for ${key}: " passphrase
    echo >&2
  else
    IFS= read -r passphrase || true
  fi
  PENDING="${sig}.tmp"
  # This is the one read of the private key. An encrypted PEM does not say its key's type
  # before the passphrase opens it, so this same call refuses a non-RSA key: only an RSA
  # key takes this padding option, and a PSS key takes only PSS, so openssl stops before
  # it signs. openssl reads the passphrase line whether or not the key needs it.
  printf '%s\n' "${passphrase}" \
    | openssl dgst -sha256 -sign "${key}" -passin stdin -sigopt rsa_padding_mode:pkcs1 -out "${PENDING}" "${manifest}" \
    || die "could not sign with ${key}: the passphrase is wrong, or it is not an RSA key; a release's signature must be RSA."
  passphrase=""
  # Whether the key is a release key shows in its signature, with no second read of it.
  verifies_under_a_release_key "${manifest}" "${PENDING}" \
    || die "${key} is none of the ${RELEASE_KEY_COUNT} release keys of ${TRUST_DOCUMENT} at v${version}; no .sig is written."
  mv "${PENDING}" "${sig}"
  echo "Wrote ${sig}. Attach it to the draft: scripts/publish-release.sh attach v${version}"
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
PENDING=""
trap 'rm -rf "${WORK}"; rm -f "${PENDING}"' EXIT

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
    sign_manifest "$@"
    ;;
esac
