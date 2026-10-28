#!/usr/bin/env bash
# Sign, or verify, a release's update manifest for the toolkit's self-update.
#
# The toolkit installs a release from the editor only when its update manifest
# (godot-mcp-toolkit-<version>.update.json, written by build-plugin-release.sh)
# carries a signature by a key listed in
# addons/godot_mcp_toolkit/update/trusted_release_keys.gd. The signature is RSA
# with SHA-256 over the manifest's exact bytes, in the file beside it with a .sig
# suffix. Sign the manifest the release workflow built, never a local build: the
# manifest pins the zip by hash.
#
# Usage:
#   scripts/sign-release.sh <manifest> <private-key.pem>
#       write <manifest>.sig, then verify it against the key's public half
#   scripts/sign-release.sh --verify <manifest> <public-key.pem>
#       check <manifest>.sig
#   scripts/sign-release.sh --key-entry <public-key.pem>
#       print the key as the GDScript string to add to PUBLIC_KEYS
#
# Make a key once (where the private half is kept is the maintainer's choice):
#   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out release-signing.pem
#   openssl pkey -in release-signing.pem -pubout -out release-signing.pub.pem
set -euo pipefail

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show' "$0" | sed 's/^# \{0,1\}//'
}

command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required." >&2; exit 2; }

case "${1:-}" in
  --verify)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    openssl dgst -sha256 -verify "$3" -signature "$2.sig" "$2"
    ;;
  --key-entry)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    openssl pkey -pubin -in "$2" -noout 2>/dev/null || { echo "error: $2 is not a PEM public key." >&2; exit 1; }
    printf '\t"'
    awk 'BEGIN { ORS = "" } { gsub(/\r/, ""); print $0 "\\n" }' "$2"
    printf '",\n'
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    [[ -f "$1" ]] || { echo "error: no manifest at $1." >&2; exit 1; }
    openssl dgst -sha256 -sign "$2" -out "$1.sig" "$1"
    PUBLIC_KEY="$(mktemp)"
    trap 'rm -f "${PUBLIC_KEY}"' EXIT
    openssl pkey -in "$2" -pubout -out "${PUBLIC_KEY}"
    openssl dgst -sha256 -verify "${PUBLIC_KEY}" -signature "$1.sig" "$1"
    echo "Wrote $1.sig. Upload it beside the manifest: gh release upload v<version> $1.sig"
    ;;
esac
