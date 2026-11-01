#!/usr/bin/env bash
# Sign, or verify, a release's update manifest for the toolkit's self-update.
#
# The toolkit installs a release from the editor only when its update manifest
# (godot-mcp-toolkit-<version>.update.json, written by build-plugin-release.sh)
# carries a signature by a key it trusts. The signature is RSA with SHA-256 over the
# manifest's exact bytes, trailing newline included, and sits beside the manifest as
# godot-mcp-toolkit-<version>.update.json.sig. That name comes from the manifest's
# version, never its path: the self-update fetches the asset by that exact name. Sign
# the manifest the release workflow built, never a local build: the manifest pins the
# zip by hash. Upload the .sig to the draft before publishing, since a published
# release may be immutable.
#
# Usage:
#   scripts/sign-release.sh <manifest> <private-key.pem> <public-key.pem>
#       write the .sig beside <manifest>: refuse a non-RSA key before signing, then
#       verify against <public-key.pem>. Pipe an encrypted key's passphrase in on
#       stdin; without a pipe, openssl prompts once.
#   scripts/sign-release.sh --verify <manifest> <public-key.pem>
#       check the .sig beside <manifest>
#   scripts/sign-release.sh --key-entry <public-key.pem>
#       print the key as one escaped string
#
# Make a key once, an encrypted RSA-2048 PEM (where the private half is kept is the
# maintainer's choice):
#   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -out release-signing.pem
#   openssl pkey -in release-signing.pem -pubout -out release-signing.pub.pem
set -euo pipefail

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show' "$0" | sed 's/^# \{0,1\}//'
}

# Prints where the manifest's signature belongs. The version becomes part of a path,
# so anything but a version is refused.
sig_path() {
  local version
  version="$(sed -nE 's/.*"version": *"([^"]*)".*/\1/p' "$1" | tr -d '\r')"
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo "error: $1 carries no usable version." >&2
    return 1
  fi
  printf '%s/godot-mcp-toolkit-%s.update.json.sig\n' "$(dirname "$1")" "${version}"
}

# The toolkit verifies PKCS#1 v1.5 RSA, and `openssl dgst -sign` would quietly emit
# something else for another key type. The check reads the public half, so it costs
# no passphrase.
require_rsa() {
  local text
  text="$(openssl pkey -pubin -in "$1" -noout -text 2>/dev/null)" || {
    echo "error: $1 is not a PEM public key." >&2
    return 1
  }
  if [[ "${text}" != *Modulus* || "${text}" == *PSS* ]]; then
    echo "error: $1 is not an RSA key; the toolkit verifies RSA signatures only." >&2
    return 1
  fi
}

command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required." >&2; exit 2; }

case "${1:-}" in
  --verify)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    [[ -f "$2" ]] || { echo "error: no manifest at $2." >&2; exit 1; }
    SIG="$(sig_path "$2")"
    [[ -f "${SIG}" ]] || { echo "error: no signature at ${SIG}." >&2; exit 1; }
    openssl dgst -sha256 -verify "$3" -signature "${SIG}" "$2"
    ;;
  --key-entry)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    openssl pkey -pubin -in "$2" -noout 2>/dev/null || { echo "error: $2 is not a PEM public key." >&2; exit 1; }
    printf '"'
    awk 'BEGIN { ORS = "" } { gsub(/\r/, ""); print $0 "\\n" }' "$2"
    printf '"\n'
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    [[ -f "$1" ]] || { echo "error: no manifest at $1." >&2; exit 1; }
    SIG="$(sig_path "$1")"
    require_rsa "$3"
    trap 'rm -f "${SIG}.tmp"' EXIT
    # This is the one read of the private key: a passphrase piped through stdin is
    # gone after it, so a second openssl call on the key would fail. openssl reads
    # that line whether or not the key needs it, so even a plain key fails on an empty
    # pipe.
    if [[ -t 0 ]]; then
      openssl dgst -sha256 -sign "$2" -out "${SIG}.tmp" "$1"
    else
      openssl dgst -sha256 -sign "$2" -passin stdin -out "${SIG}.tmp" "$1"
    fi
    openssl dgst -sha256 -verify "$3" -signature "${SIG}.tmp" "$1" || {
      echo "error: the signature does not verify against $3; is it the private key's public half?" >&2
      exit 1
    }
    mv "${SIG}.tmp" "${SIG}"
    echo "Wrote ${SIG}. Upload it to the draft before publishing: gh release upload v<version> ${SIG}"
    ;;
esac
