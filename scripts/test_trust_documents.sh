#!/usr/bin/env bash
# scripts/test_trust_documents.sh
# Tests scripts/trust-document.sh with keys made at run time, with no network and no change to
# the repo: the exact shape of what it writes, signing with an encrypted key through stdin, and
# the same refusals as the reader in the toolkit, checked on files made here without the script.
#
# With TRUST_DOCUMENTS_GODOT naming a Godot binary it also hands a chain made in this run to the
# real reader, through test/tools/read_trust_documents.gd, and checks a document the reader's own
# side wrote. TRUST_DOCUMENTS_EXPECT_OPENSSL fails the run unless `openssl version` holds that
# text, since a PATH can hide the build a job means to test.
#
# The RSA-PSS case needs an openssl that makes such a key; it says "skip" without one.
#
# Usage: bash scripts/test_trust_documents.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO_ROOT}/scripts/trust-document.sh"

# Through cd and pwd for a path with no drive colon: it goes on the PATH below.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-trust-documents.XXXXXX")" && pwd)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
SKIPPED=0

check() {
  local label="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "  ok    ${label}"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${label}"
    echo "        last output: ${OUT:-}"
  fi
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  echo "  skip  ${1}"
}

equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
matches() { [[ "$1" =~ $2 ]]; }
is_file() { [[ -f "$1" ]]; }
no_file() { [[ ! -e "$1" ]]; }
same_bytes() { cmp -s "$1" "$2"; }
verifies() { openssl dgst -sha256 -verify "$1" -signature "$2" "$3" >/dev/null 2>&1; }

# Runs a command and keeps its combined output and exit status.
run() {
  OUT="$("$@" 2>&1)" && STATUS=0 || STATUS=$?
}

tool() {
  run bash "${TOOL}" "$@"
}

# Signs through a pipe: the line piped in is the passphrase, and openssl takes it whether or not
# the key needs one.
sign_piped() {
  OUT="$(printf '%s\n' "$1" | bash "${TOOL}" sign "$2" "$3" 2>&1)" && STATUS=0 || STATUS=$?
}

# Checks that the tool refused with exit 1, whose reason holds the text $2.
refused() {
  local label="$1" reason="$2"
  check "${label}: refused" equals "${STATUS}" "1"
  check "${label}: says why" contains "${OUT}" "${reason}"
}

# base64 with no line break, whatever this openssl does about lines.
base64_of() {
  openssl base64 -in "$1" | tr -d '\r\n'
}

# Decodes the base64 text $1 into the file $2, with this openssl's default line length.
decode_to() {
  printf '%s' "$1" | fold -w 64 | openssl base64 -d -out "$2"
}

# A key as the JSON string a document holds.
key_json() {
  printf '"%s"' "$(tr -d '\r' < "$1" | awk 'BEGIN { ORS = "" } { print $0 "\\n" }')"
}

# The decoded document of version $1, roots $2, threshold $3 and release keys $4.
body_text() {
  printf '{"format": 1, "version": %s, "root_keys": [%s], "root_threshold": %s, "release_keys": [%s]}\n' "$1" "$2" "$3" "$4"
}

# Writes the document file $1 for the decoded text $2, signed with the plain private keys after
# it, without the tool, so a refusal is the tool's reading rather than its writing. No space in
# the outer object, the way the reader's side writes one.
make_file() {
  local out="$1" text="$2" signatures="" key
  shift 2
  printf '%s' "${text}" > "${WORK}/made.decoded"
  for key in ${1+"$@"}; do
    openssl dgst -sha256 -sign "${key}" -out "${WORK}/made.signature" "${WORK}/made.decoded" </dev/null
    signatures="${signatures:+${signatures},}\"$(base64_of "${WORK}/made.signature")\""
  done
  printf '{"document":"%s","signatures":[%s]}\n' "$(base64_of "${WORK}/made.decoded")" "${signatures}" > "${out}"
}

# Prints the file $1's text with the character at the offset $2 changed.
with_one_change() {
  local text character replacement
  text="$(cat "$1")"
  character="${text:$2:1}"
  replacement="A"
  [[ "${character}" != "A" ]] || replacement="B"
  printf '%s%s%s\n' "${text:0:$2}" "${replacement}" "${text:$(($2 + 1))}"
}

if [[ -n "${TRUST_DOCUMENTS_EXPECT_OPENSSL:-}" ]]; then
  OPENSSL_VERSION="$(openssl version)"
  echo "${OPENSSL_VERSION}"
  if [[ "${OPENSSL_VERSION}" != *"${TRUST_DOCUMENTS_EXPECT_OPENSSL}"* ]]; then
    echo "error: expected ${TRUST_DOCUMENTS_EXPECT_OPENSSL}, got: ${OPENSSL_VERSION}" >&2
    exit 1
  fi
fi

KEYS="${WORK}/keys"
mkdir -p "${KEYS}"
PASSPHRASE="correct horse battery staple"
for name in root other_root first_release next_release; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/${name}.pem" 2>/dev/null
  openssl pkey -in "${KEYS}/${name}.pem" -pubout -out "${KEYS}/${name}.pub.pem"
done
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -pass "pass:${PASSPHRASE}" \
  -out "${KEYS}/encrypted.pem" 2>/dev/null
openssl pkey -in "${KEYS}/encrypted.pem" -passin "pass:${PASSPHRASE}" -pubout -out "${KEYS}/encrypted.pub.pem"
openssl ecparam -name prime256v1 -genkey -noout -out "${KEYS}/ec.pem" 2>/dev/null
openssl pkey -in "${KEYS}/ec.pem" -pubout -out "${KEYS}/ec.pub.pem"
# The same key in another layout: CRLF line ends.
awk '{ printf "%s\r\n", $0 }' "${KEYS}/root.pub.pem" > "${KEYS}/root.crlf.pub.pem"

ROOT_JSON="$(key_json "${KEYS}/root.pub.pem")"
OTHER_ROOT_JSON="$(key_json "${KEYS}/other_root.pub.pem")"
ENCRYPTED_JSON="$(key_json "${KEYS}/encrypted.pub.pem")"
FIRST_RELEASE_JSON="$(key_json "${KEYS}/first_release.pub.pem")"
NEXT_RELEASE_JSON="$(key_json "${KEYS}/next_release.pub.pem")"

UNUSED_LINE="not read by a plain key"
BASE64='[A-Za-z0-9+/]+={0,2}'

echo "── usage ──"
tool
check "no argument prints the usage" contains "${OUT}" "Usage:"
check "no argument exits 0" equals "${STATUS}" "0"
tool frobnicate
check "an unknown command is wrong usage" equals "${STATUS}" "2"
tool sign only-one-argument
check "sign with one argument is wrong usage" equals "${STATUS}" "2"
tool verify only-one-argument
check "verify with one argument is wrong usage" equals "${STATUS}" "2"
tool build
check "build with no previous and no --first is wrong usage" equals "${STATUS}" "2"
tool build --first --drop-root "${KEYS}/root.pub.pem"
check "a first document drops nothing" equals "${STATUS}" "2"

echo "── build --first ──"
CHAIN="${WORK}/chain"
mkdir -p "${CHAIN}"
tool build --first --add-root "${KEYS}/encrypted.pub.pem" --add-release "${KEYS}/first_release.pub.pem" --out "${CHAIN}"
FIRST="${CHAIN}/trust-1.json"
check "writes trust-1.json" is_file "${FIRST}"
check "the outer shape is exact, with no signature yet" matches "$(cat "${FIRST}")" "^\{\"document\": \"${BASE64}\", \"signatures\": \[\]\}\$"
check "the file is one line, ended by one LF" equals "$(wc -l < "${FIRST}" | tr -d ' ')" "1"
check "the file holds no CR" lacks "$(cat "${FIRST}")" $'\r'
tool show "${FIRST}"
SHOWN="${OUT}"
check "the decoded document is exact" equals "${SHOWN}" "$(body_text 1 "${ENCRYPTED_JSON}" 1 "${FIRST_RELEASE_JSON}")"
ENCODED="$(cat "${FIRST}")"
ENCODED="${ENCODED#*\"document\": \"}"
ENCODED="${ENCODED%%\"*}"
decode_to "${ENCODED}" "${WORK}/first.decoded"
body_text 1 "${ENCRYPTED_JSON}" 1 "${FIRST_RELEASE_JSON}" > "${WORK}/first.expected"
check "the base64 decodes to those bytes, one LF at the end" same_bytes "${WORK}/first.decoded" "${WORK}/first.expected"
tool build --first --add-root "${KEYS}/encrypted.pub.pem" --out "${CHAIN}"
refused "an existing document" "already exists"
tool build --first --add-release "${KEYS}/first_release.pub.pem" --out "${WORK}"
refused "no root key" "at least one root key"
tool build --first --add-root "${KEYS}/ec.pub.pem" --out "${WORK}"
refused "an EC root key" "not an RSA key"
tool build --first --add-root "${KEYS}/root.pem" --out "${WORK}"
refused "a private key where a public one belongs" "not a PEM public key"
check "those refusals write nothing" no_file "${WORK}/trust-1.json"

LAYOUTS="${WORK}/layouts"
mkdir -p "${LAYOUTS}/lf" "${LAYOUTS}/crlf"
tool build --first --add-root "${KEYS}/root.pub.pem" --out "${LAYOUTS}/lf"
tool build --first --add-root "${KEYS}/root.crlf.pub.pem" --out "${LAYOUTS}/crlf"
check "a PEM with CRLF line ends writes the same bytes" same_bytes "${LAYOUTS}/lf/trust-1.json" "${LAYOUTS}/crlf/trust-1.json"

echo "── sign ──"
cp "${FIRST}" "${WORK}/unsigned.json"
tool verify --first "${FIRST}"
refused "an unsigned first document" "of its own roots signed"
sign_piped "not-the-passphrase" "${FIRST}" "${KEYS}/encrypted.pem"
check "the wrong passphrase fails" equals "${STATUS}" "1"
check "the wrong passphrase leaves the file alone" same_bytes "${FIRST}" "${WORK}/unsigned.json"

# An openssl on the PATH that logs each call before running the real one.
REAL_OPENSSL="$(command -v openssl)"
export REAL_OPENSSL
export OPENSSL_LOG="${WORK}/openssl.log"
mkdir -p "${WORK}/stub"
cat > "${WORK}/stub/openssl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OPENSSL_LOG}"
exec "${REAL_OPENSSL}" "$@"
STUB
chmod +x "${WORK}/stub/openssl"
ORIGINAL_PATH="${PATH}"
PATH="${WORK}/stub:${ORIGINAL_PATH}"
sign_piped "${PASSPHRASE}" "${FIRST}" "${KEYS}/encrypted.pem"
PATH="${ORIGINAL_PATH}"
check "an encrypted key through stdin signs" equals "${STATUS}" "0"
check "the private key is read exactly once" equals "$(grep -c -F "${KEYS}/encrypted.pem" "${OPENSSL_LOG}")" "1"
check "the outer shape is exact, with one signature" matches "$(cat "${FIRST}")" "^\{\"document\": \"${BASE64}\", \"signatures\": \[\"${BASE64}\"\]\}\$"
check "the file is still one line" equals "$(wc -l < "${FIRST}" | tr -d ' ')" "1"
SIGNATURE="$(cat "${FIRST}")"
SIGNATURE="${SIGNATURE#*\"signatures\": \[\"}"
SIGNATURE="${SIGNATURE%%\"*}"
check "an RSA-2048 signature is 344 characters, unwrapped" equals "${#SIGNATURE}" "344"
decode_to "${SIGNATURE}" "${WORK}/first.signature"
check "the signature is RSA with SHA-256 over the decoded bytes" verifies "${KEYS}/encrypted.pub.pem" "${WORK}/first.signature" "${WORK}/first.decoded"
tool show "${FIRST}"
check "signing leaves the document alone" equals "${OUT}" "${SHOWN}"
tool verify --first "${FIRST}"
check "verify --first accepts it" equals "${STATUS}" "0"
check "verify says which version holds" contains "${OUT}" "version 1 holds"

cp "${FIRST}" "${WORK}/signed.json"
sign_piped "${PASSPHRASE}" "${FIRST}" "${KEYS}/encrypted.pem"
refused "the same key again" "already signed"
check "that refusal leaves the file alone" same_bytes "${FIRST}" "${WORK}/signed.json"
sign_piped "${UNUSED_LINE}" "${FIRST}" "${KEYS}/ec.pem"
refused "an EC key" "must be RSA"
check "that refusal leaves the file alone" same_bytes "${FIRST}" "${WORK}/signed.json"
sign_piped "${UNUSED_LINE}" "${FIRST}" "${WORK}/no-such-key.pem"
refused "a missing key" "no key at"
sign_piped "${UNUSED_LINE}" "${WORK}/no-such-document.json" "${KEYS}/root.pem"
refused "a missing document" "no document at"

# An RSA-PSS key prints a modulus like a plain RSA key, but signs with another padding.
if openssl genpkey -algorithm RSA-PSS -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/pss.pem" 2>/dev/null \
  && openssl pkey -in "${KEYS}/pss.pem" -pubout -out "${KEYS}/pss.pub.pem" 2>/dev/null \
  && openssl pkey -pubin -in "${KEYS}/pss.pub.pem" -noout -text >/dev/null 2>&1; then
  sign_piped "${UNUSED_LINE}" "${FIRST}" "${KEYS}/pss.pem"
  refused "an RSA-PSS key" "must be RSA"
  check "that refusal leaves the file alone" same_bytes "${FIRST}" "${WORK}/signed.json"
  tool build --first --add-root "${KEYS}/pss.pub.pem" --out "${WORK}"
  refused "an RSA-PSS root key" "not an RSA key"
else
  skip "the RSA-PSS case needs an openssl that makes and prints such a key"
fi

echo "── a one-byte tamper ──"
# Each offset falls inside the base64, past the field's name.
TAMPERED="${WORK}/tampered"
mkdir -p "${TAMPERED}"
with_one_change "${FIRST}" 20 > "${TAMPERED}/document.json"
tool verify --first "${TAMPERED}/document.json"
check "one changed byte in the document fails" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"
TEXT="$(cat "${FIRST}")"
PREFIX="${TEXT%%\"signatures\"*}"
with_one_change "${FIRST}" "$(( ${#PREFIX} + 30 ))" > "${TAMPERED}/signature.json"
tool verify --first "${TAMPERED}/signature.json"
refused "one changed byte in the signature" "of its own roots signed"
make_file "${TAMPERED}/other-signer.json" "$(body_text 1 "${ROOT_JSON}" 1 "")" "${KEYS}/other_root.pem"
tool verify --first "${TAMPERED}/other-signer.json"
refused "a signature by a key the document does not list" "of its own roots signed"

echo "── build and verify the next document ──"
SECOND="${CHAIN}/trust-2.json"
tool build "${FIRST}" --add-release "${KEYS}/next_release.pub.pem" --drop-release "${KEYS}/first_release.pub.pem"
check "writes the next number beside the previous" is_file "${SECOND}"
tool show "${SECOND}"
check "a rotation's document lists the new key and not the old one" equals "${OUT}" "$(body_text 2 "${ENCRYPTED_JSON}" 1 "${NEXT_RELEASE_JSON}")"
tool verify "${FIRST}" "${SECOND}"
refused "the next document unsigned" "of the previous roots signed"
sign_piped "${PASSPHRASE}" "${SECOND}" "${KEYS}/encrypted.pem"
tool verify "${FIRST}" "${SECOND}"
check "verify accepts it signed by the same root" equals "${STATUS}" "0"
check "verify reports both thresholds" contains "${OUT}" "previous roots: 1 signed, 1 needed"
tool build "${FIRST}"
refused "a next document that exists" "already exists"

BUILT="${WORK}/built"
mkdir -p "${BUILT}"
tool build "${FIRST}" --out "${BUILT}" --drop-release "${KEYS}/next_release.pub.pem"
refused "dropping a key the document does not list" "not a release key"
tool build "${FIRST}" --out "${BUILT}" --add-release "${KEYS}/first_release.pub.pem"
refused "adding a key it lists" "already a release key"
tool build "${FIRST}" --out "${BUILT}" --threshold 2
refused "a threshold above its roots" "not between 1"
tool build "${FIRST}" --out "${BUILT}" --threshold 0
refused "a threshold of 0" "not between 1"
tool build "${FIRST}" --out "${BUILT}" --drop-root "${KEYS}/encrypted.pub.pem"
refused "dropping the last root" "at least one root key"
check "those refusals write nothing" no_file "${BUILT}/trust-2.json"

tool build "${FIRST}" --out "${BUILT}" --drop-release "${KEYS}/first_release.pub.pem"
check "dropping every release key is allowed" equals "${STATUS}" "0"
check "and it warns what that does" contains "${OUT}" "stops all updates"
sign_piped "${PASSPHRASE}" "${BUILT}/trust-2.json" "${KEYS}/encrypted.pem"
tool verify "${FIRST}" "${BUILT}/trust-2.json"
check "the emergency stop verifies" equals "${STATUS}" "0"
check "verify says what it does" contains "${OUT}" "stops all updates"

echo "── a change of roots ──"
THIRD="${CHAIN}/trust-3.json"
tool build "${SECOND}" --add-root "${KEYS}/other_root.pub.pem" --drop-root "${KEYS}/encrypted.pub.pem"
ROOT_CHANGE="${WORK}/root-change"
mkdir -p "${ROOT_CHANGE}/old" "${ROOT_CHANGE}/new"
cp "${THIRD}" "${ROOT_CHANGE}/old/trust-3.json"
cp "${THIRD}" "${ROOT_CHANGE}/new/trust-3.json"
sign_piped "${PASSPHRASE}" "${ROOT_CHANGE}/old/trust-3.json" "${KEYS}/encrypted.pem"
tool verify "${SECOND}" "${ROOT_CHANGE}/old/trust-3.json"
refused "signed only by the old root" "of its own roots signed"
sign_piped "${UNUSED_LINE}" "${ROOT_CHANGE}/new/trust-3.json" "${KEYS}/other_root.pem"
tool verify "${SECOND}" "${ROOT_CHANGE}/new/trust-3.json"
refused "signed only by the new root" "of the previous roots signed"
sign_piped "${PASSPHRASE}" "${THIRD}" "${KEYS}/encrypted.pem"
sign_piped "${UNUSED_LINE}" "${THIRD}" "${KEYS}/other_root.pem"
check "the second signature goes in" equals "${STATUS}" "0"
check "the outer shape is exact, with two signatures" matches "$(cat "${THIRD}")" "^\{\"document\": \"${BASE64}\", \"signatures\": \[\"${BASE64}\", \"${BASE64}\"\]\}\$"
tool verify "${SECOND}" "${THIRD}"
check "signed by both, it verifies" equals "${STATUS}" "0"

echo "── thresholds and distinct keys ──"
TWO="${WORK}/two"
mkdir -p "${TWO}"
tool build --first --add-root "${KEYS}/root.pub.pem" --add-root "${KEYS}/other_root.pub.pem" --threshold 2 --out "${TWO}"
tool build --first --add-root "${KEYS}/root.crlf.pub.pem" --add-root "${KEYS}/root.pub.pem" --out "${WORK}"
refused "one root in two layouts" "already a root key"
sign_piped "${UNUSED_LINE}" "${TWO}/trust-1.json" "${KEYS}/root.pem"
tool verify --first "${TWO}/trust-1.json"
refused "one signature of a threshold of 2" "1 of its own roots signed"
sign_piped "${UNUSED_LINE}" "${TWO}/trust-1.json" "${KEYS}/other_root.pem"
tool verify --first "${TWO}/trust-1.json"
check "two signatures of a threshold of 2" equals "${STATUS}" "0"

HAND="${WORK}/hand"
mkdir -p "${HAND}"
ROOT_CRLF_JSON="$(printf '"%s"' "$(awk 'BEGIN { ORS = "" } { gsub(/\r/, ""); print $0 "\\r\\n" }' "${KEYS}/root.crlf.pub.pem")")"
make_file "${HAND}/repeated-key.json" "$(body_text 1 "${ROOT_JSON}, ${ROOT_CRLF_JSON}" 2 "")" "${KEYS}/root.pem"
tool verify --first "${HAND}/repeated-key.json"
refused "a key listed twice in two layouts counts once" "above its 1 distinct root keys"
make_file "${HAND}/repeated-key-threshold-1.json" "$(body_text 1 "${ROOT_JSON}, ${ROOT_CRLF_JSON}" 1 "")" "${KEYS}/root.pem"
tool verify --first "${HAND}/repeated-key-threshold-1.json"
check "and it counts as one of one" contains "${OUT}" "1 of 1 signed"
make_file "${HAND}/repeated-signature.json" "$(body_text 1 "${ROOT_JSON}, ${OTHER_ROOT_JSON}" 2 "")" "${KEYS}/root.pem" "${KEYS}/root.pem"
tool verify --first "${HAND}/repeated-signature.json"
refused "one key's signature twice counts once" "1 of its own roots signed"

# The same next document both ways, valid against its own roots, so only the previous roots'
# threshold can tell the two apart.
NEXT_OF_TWO="$(body_text 2 "${ROOT_JSON}" 1 "")"
make_file "${HAND}/one-of-two-previous.json" "${NEXT_OF_TWO}" "${KEYS}/root.pem"
tool verify "${TWO}/trust-1.json" "${HAND}/one-of-two-previous.json"
refused "one signature of a previous threshold of 2" "1 of the previous roots signed it, and it needs 2"
make_file "${HAND}/two-of-two-previous.json" "${NEXT_OF_TWO}" "${KEYS}/root.pem" "${KEYS}/other_root.pem"
tool verify "${TWO}/trust-1.json" "${HAND}/two-of-two-previous.json"
check "control: two signatures of a previous threshold of 2" equals "${STATUS}" "0"
check "and the previous threshold it met is 2" contains "${OUT}" "previous roots: 2 signed, 2 needed"

echo "── refusals, on files the tool did not make ──"
ONE_ROOT="${WORK}/one-root.json"
make_file "${ONE_ROOT}" "$(body_text 1 "${ROOT_JSON}" 1 "${FIRST_RELEASE_JSON}")" "${KEYS}/root.pem"
tool verify --first "${ONE_ROOT}"
check "the compact outer object the reader's side writes verifies" equals "${STATUS}" "0"

verify_made() {
  local label="$1" reason="$2" text="$3"
  make_file "${HAND}/case.json" "${text}" "${KEYS}/root.pem"
  tool verify "${ONE_ROOT}" "${HAND}/case.json"
  refused "${label}" "${reason}"
}
verify_made "a skipped version" "must be 2" "$(body_text 3 "${ROOT_JSON}" 1 "")"
verify_made "a repeated version" "must be 2" "$(body_text 1 "${ROOT_JSON}" 1 "")"
verify_made "a version that is text" "wrong type" '{"format": 1, "version": "2", "root_keys": [], "root_threshold": 1, "release_keys": []}'
verify_made "a version below 1" "whole number" "$(body_text 0 "${ROOT_JSON}" 1 "")"
verify_made "a fractional version" "whole number" "$(body_text 2.5 "${ROOT_JSON}" 1 "")"
verify_made "a threshold of 0" "root threshold" "$(body_text 2 "${ROOT_JSON}" 0 "")"
verify_made "a threshold above the roots" "above its 1 distinct" "$(body_text 2 "${ROOT_JSON}" 2 "")"
verify_made "empty root keys" "root keys are empty" "$(body_text 2 "" 1 "")"
verify_made "a root that does not load" "not a PEM public key" "$(body_text 2 '"not a key"' 1 "")"
verify_made "an EC root" "not an RSA key" "$(body_text 2 "$(key_json "${KEYS}/ec.pub.pem")" 1 "")"
verify_made "a release key that does not load" "not a PEM public key" "$(body_text 2 "${ROOT_JSON}" 1 '"not a key"')"
verify_made "a key that is not a string" "not a string" "$(body_text 2 "${ROOT_JSON}, 7" 1 "")"
verify_made "another format" "format is not 1" '{"format": 2, "version": 2, "root_keys": [], "root_threshold": 1, "release_keys": []}'
verify_made "release keys that are not a list" "wrong type" '{"format": 1, "version": 2, "root_keys": [], "root_threshold": 1, "release_keys": "none"}'
verify_made "a document that is not JSON" "not a JSON object" "not json"
verify_made "a repeated field" "not a JSON object" '{"format": 1, "format": 1}'

check_named() {
  make_file "${HAND}/$1" "$2" "${KEYS}/root.pem"
  tool verify "${ONE_ROOT}" "${HAND}/$1"
}
check_named "trust-2.json" "$(body_text 2 "${ROOT_JSON}" 1 "")"
check "control: a file named for its version verifies" equals "${STATUS}" "0"
mkdir -p "${HAND}/seven"
cp "${HAND}/trust-2.json" "${HAND}/seven/trust-7.json"
tool verify "${ONE_ROOT}" "${HAND}/seven/trust-7.json"
refused "a file named 7 that holds 2" "holds version 2"

printf '{"document": "not base64!", "signatures": []}\n' > "${HAND}/bad-document.json"
tool verify "${ONE_ROOT}" "${HAND}/bad-document.json"
refused "a document that does not decode" "does not decode"
GOOD_DOCUMENT="$(base64_of "${WORK}/first.expected")"
printf '{"document": "%s", "signatures": ["not base64!"]}\n' "${GOOD_DOCUMENT}" > "${HAND}/bad-signature.json"
tool verify "${ONE_ROOT}" "${HAND}/bad-signature.json"
refused "a signature that does not decode" "does not decode"
printf '{"document": "%s", "signatures": [""]}\n' "${GOOD_DOCUMENT}" > "${HAND}/empty-signature.json"
tool verify "${ONE_ROOT}" "${HAND}/empty-signature.json"
refused "an empty signature" "does not decode"
printf '{"document": "", "signatures": []}\n' > "${HAND}/empty-document.json"
tool verify "${ONE_ROOT}" "${HAND}/empty-document.json"
refused "an empty document" "does not hold a document"
printf '{"document": "%s", "signatures": [7]}\n' "${GOOD_DOCUMENT}" > "${HAND}/number-signature.json"
tool verify "${ONE_ROOT}" "${HAND}/number-signature.json"
refused "a signature that is not a string" "not a string"
printf '{"document": "%s"}\n' "${GOOD_DOCUMENT}" > "${HAND}/no-signatures.json"
tool verify "${ONE_ROOT}" "${HAND}/no-signatures.json"
refused "no signatures field" "does not hold a document"
printf 'not json\n' > "${HAND}/not-json.json"
tool verify "${ONE_ROOT}" "${HAND}/not-json.json"
refused "a file that is not JSON" "not a JSON object"
printf '{"document": "%s", "signatures": []} trailing\n' "${GOOD_DOCUMENT}" > "${HAND}/trailing.json"
tool verify "${ONE_ROOT}" "${HAND}/trailing.json"
refused "text after the object" "not a JSON object"
tool verify "${ONE_ROOT}" "${HAND}/no-such-file.json"
refused "a missing file" "no document at"

make_file "${HAND}/no-document.json" "not json"
cp "${HAND}/no-document.json" "${HAND}/no-document.before.json"
sign_piped "${UNUSED_LINE}" "${HAND}/no-document.json" "${KEYS}/root.pem"
refused "signing an envelope whose decoded bytes are no document" "the document is not a JSON object"
check "that refusal writes nothing" same_bytes "${HAND}/no-document.json" "${HAND}/no-document.before.json"

ONE_SIGNATURE="$(cat "${ONE_ROOT}")"
ONE_SIGNATURE="${ONE_SIGNATURE#*\"signatures\":\[\"}"
ONE_SIGNATURE="${ONE_SIGNATURE%%\"*}"
SEVENTEEN=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
  SEVENTEEN="${SEVENTEEN:+${SEVENTEEN}, }\"${ONE_SIGNATURE}\""
done
printf '{"document": "%s", "signatures": [%s]}\n' "${GOOD_DOCUMENT}" "${SEVENTEEN}" > "${HAND}/seventeen.json"
tool verify "${ONE_ROOT}" "${HAND}/seventeen.json"
refused "more than 16 signatures" "more than 16"
openssl rand 4097 > "${WORK}/long.signature"
printf '{"document": "%s", "signatures": ["%s"]}\n' "${GOOD_DOCUMENT}" "$(base64_of "${WORK}/long.signature")" > "${HAND}/long-signature.json"
tool verify "${ONE_ROOT}" "${HAND}/long-signature.json"
refused "a signature over 4096 bytes" "larger than 4096"
awk 'BEGIN { for (i = 0; i < 1048576; i++) printf " " }' > "${WORK}/padding"
cat "${ONE_ROOT}" "${WORK}/padding" > "${HAND}/oversized.json"
tool verify --first "${HAND}/oversized.json"
refused "a file over 1 MiB" "larger than 1048576"

echo "── what the reader tolerates ──"
awk '{ printf "%s\r\n", $0 }' "${SECOND}" > "${HAND}/crlf.json"
tool verify "${FIRST}" "${HAND}/crlf.json"
check "a CRLF in the outer file changes nothing" equals "${STATUS}" "0"
make_file "${HAND}/unknown-field.json" "$(printf '{"pins": {"1.2.0": ["a", "b"]}, "release_keys": [%s], "root_threshold": 1, "root_keys": [%s], "version": 2, "format": 1}\n' "${FIRST_RELEASE_JSON}" "${ROOT_JSON}")" "${KEYS}/root.pem"
tool verify "${ONE_ROOT}" "${HAND}/unknown-field.json"
check "an unknown field and another field order verify" equals "${STATUS}" "0"
mkdir -p "${HAND}/after-unknown"
tool build "${HAND}/unknown-field.json" --out "${HAND}/after-unknown"
check "a build from it warns the field is left out" contains "${OUT}" "leaves out pins"

echo "── trust/released-manifests.txt ──"
LEDGER="${REPO_ROOT}/trust/released-manifests.txt"
check "the ledger exists" is_file "${LEDGER}"
OUT="$(tr -d '\r' < "${LEDGER}" | grep -v -E '^#|^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)? [0-9a-f]{64}$' || true)"
check "each line is a comment, or a version and a SHA-256" equals "${OUT}" ""

echo "── the real reader ──"
if [[ -n "${TRUST_DOCUMENTS_GODOT:-}" ]]; then
  READER="${WORK}/reader"
  mkdir -p "${READER}/chain" "${READER}/refused"
  cp "${FIRST}" "${SECOND}" "${THIRD}" "${READER}/chain/"
  printf 'the manifest of a later release\n' > "${READER}/manifest.txt"
  openssl dgst -sha256 -sign "${KEYS}/next_release.pem" -out "${READER}/new-key.signature" "${READER}/manifest.txt"
  openssl dgst -sha256 -sign "${KEYS}/first_release.pem" -out "${READER}/dropped-key.signature" "${READER}/manifest.txt"

  tool build "${THIRD}" --out "${READER}" --add-release "${KEYS}/first_release.pub.pem"
  tool show "${READER}/trust-4.json"
  FOURTH_TEXT="${OUT}"
  cp "${READER}/trust-4.json" "${READER}/refused/unsigned.json"
  sign_piped "${UNUSED_LINE}" "${READER}/trust-4.json" "${KEYS}/other_root.pem"
  mv "${READER}/trust-4.json" "${READER}/next.json"
  with_one_change "${READER}/next.json" 20 > "${READER}/refused/tampered.json"
  make_file "${READER}/refused/skipped.json" "$(body_text 5 "${OTHER_ROOT_JSON}" 1 "")" "${KEYS}/other_root.pem"
  make_file "${READER}/refused/wrong-signer.json" "${FOURTH_TEXT}"$'\n' "${KEYS}/root.pem"
  make_file "${READER}/refused/threshold-zero.json" "$(body_text 4 "${OTHER_ROOT_JSON}" 0 "")" "${KEYS}/other_root.pem"

  # What the reader refuses below, the tool must refuse too, and the document it takes, the tool
  # takes: the two readings cannot part.
  tool verify "${THIRD}" "${READER}/next.json"
  check "the tool takes the next document" equals "${STATUS}" "0"
  for refused_file in "${READER}"/refused/*.json; do
    tool verify "${THIRD}" "${refused_file}"
    check "the tool refuses $(basename "${refused_file}")" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"
  done

  # The runtime's autoload would bind a port and take this project's registry entry.
  OUT="$(GODOT_MCP_RUNTIME=0 "${TRUST_DOCUMENTS_GODOT}" --headless --path "${REPO_ROOT}" --script res://test/tools/read_trust_documents.gd -- "${READER}" 2>&1)" || true
  echo "${OUT}" | grep -a -E '^  (ok|FAIL) ' || true
  check "the reader's verdict on this run's documents" contains "${OUT}" "TRUST_READER_RESULT pass"
  tool verify --first "${READER}/godot-made.json"
  check "the tool takes a document the reader's side wrote" equals "${STATUS}" "0"
else
  skip "reading a run-time document in Godot needs TRUST_DOCUMENTS_GODOT"
fi

echo ""
echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped ($(openssl version))"
[[ "${FAILED}" -eq 0 ]]
