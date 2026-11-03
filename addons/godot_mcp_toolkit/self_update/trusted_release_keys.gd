@tool
extends RefCounted
## The public keys whose signature makes a release installable from the editor.
##
## Each entry is a PEM public key ([code]-----BEGIN PUBLIC KEY-----[/code]). The
## maintainer holds the matching private key and signs each release's update
## manifest with [code]scripts/sign-release.sh[/code]. While the list is empty no
## release verifies, so the toolkit offers updates as links only, as before.[br]
## [br]
## To rotate a key, ship a release whose list holds the old and the new key, signed
## with the old one; sign the next release with the new key and drop the old one.

const PUBLIC_KEYS := []
