# shellcheck shell=bash
#
# scripts/lib/release_identity.sh: which repository a release comes from, pinned in the
# repository itself.
#
# Sourced, never run. The release scripts compare what they are told by git, gh and the
# environment against these values and refuse on any difference, so nothing but a commit
# on main can point them at another repository or another first trust document.
#
#   RELEASE_SLUG            the repository, as owner/name
#   RELEASE_ORIGIN_URL      the URL origin must have, exactly: the anonymous HTTPS clone URL
#   RELEASE_BRANCH          the branch every release tag must be on
#   RELEASE_TRUST_1_SHA256  the SHA-256 of trust/trust-1.json's bytes, the document every
#                           1.2.0 client trusts first; no tag may carry another

# shellcheck disable=SC2034 # read by the scripts that source this file
RELEASE_SLUG='NPGameDev/godot-mcp-toolkit'
# shellcheck disable=SC2034
RELEASE_ORIGIN_URL='https://github.com/NPGameDev/godot-mcp-toolkit.git'
# shellcheck disable=SC2034
RELEASE_BRANCH='main'
# shellcheck disable=SC2034
RELEASE_TRUST_1_SHA256='af840ce40fd37e1e79d0079e2074d7efd19f5ae3bfdb34ae2a08af70dfe9060e'
