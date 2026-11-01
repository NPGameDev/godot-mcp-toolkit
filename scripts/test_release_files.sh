#!/usr/bin/env bash
# scripts/test_release_files.sh
# Tests the files a release publishes and the scripts around them, with no network, no
# Godot and no change to the repo. Fixtures and keys are generated at run time, so line
# endings in a checkout cannot move a pinned hash, and no key lives in the repo:
#   - scripts/lib/release_files.sh against known SHA-256 vectors and a fixed manifest;
#   - both build scripts on a fixture repo: the missing .uid and the unreadable commit
#     time refused, the list and manifest pinned, the .ps1 matching them;
#   - scripts/sign-release.sh with plain, encrypted, mismatched and non-RSA keys;
#   - scripts/check_release_files.sh's failures.
#
# The real builds need zip, unzip and pwsh, and those checks say "skip" without them.
# RELEASE_FILES_REQUIRE_ALL=1 turns a skip into a failure; RELEASE_FILES_PS names
# another PowerShell than pwsh.
#
# Usage: bash scripts/test_release_files.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

# Through cd and pwd for a path with no drive colon: it goes on the PATH below.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-release-files.XXXXXX")" && pwd)"
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
  fi
}

skip() {
  if [[ "${RELEASE_FILES_REQUIRE_ALL:-0}" == "1" ]]; then
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${1} (RELEASE_FILES_REQUIRE_ALL is set)"
  else
    SKIPPED=$((SKIPPED + 1))
    echo "  skip  ${1}"
  fi
}

equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
is_file() { [[ -f "$1" ]]; }
no_file() { [[ ! -e "$1" ]]; }
same_bytes() { cmp -s "$1" "$2"; }
verifies() { openssl dgst -sha256 -verify "$1" -signature "$2" "$3" >/dev/null 2>&1; }
file_size() { wc -c < "$1" | tr -d ' '; }

# Runs a command and keeps its combined output and exit status.
run() {
  OUT="$("$@" 2>&1)" && STATUS=0 || STATUS=$?
}

# Known SHA-256 vectors: the empty input and FIPS 180's two "abc" messages, plus "hello\n".
HASH_EMPTY="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
HASH_ABC="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
HASH_HELLO="5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
FIPS_LONG="abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
HASH_FIPS_LONG="248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

echo "── rf_sha256 ──"
printf '' > "${WORK}/empty"
printf 'abc' > "${WORK}/abc"
printf 'hello\n' > "${WORK}/hello"
check "the empty input" equals "$(rf_sha256 "${WORK}/empty")" "${HASH_EMPTY}"
check "abc" equals "$(rf_sha256 "${WORK}/abc")" "${HASH_ABC}"
check "hello and a newline" equals "$(rf_sha256 "${WORK}/hello")" "${HASH_HELLO}"

echo "── rf_write_list ──"
LIST_DIR="${WORK}/list"
mkdir -p "${LIST_DIR}/nested/deep"
printf '' > "${LIST_DIR}/.hidden"
printf 'abc' > "${LIST_DIR}/Zed.txt"
printf 'hello\n' > "${LIST_DIR}/a b.txt"
printf '%s' "${FIPS_LONG}" > "${LIST_DIR}/nested/deep/file.txt"
printf 'a stale list\n' > "${LIST_DIR}/release_files.sha256"
rf_write_list "${LIST_DIR}"
{
  printf '%s  .hidden\n' "${HASH_EMPTY}"
  printf '%s  Zed.txt\n' "${HASH_ABC}"
  printf '%s  a b.txt\n' "${HASH_HELLO}"
  printf '%s  nested/deep/file.txt\n' "${HASH_FIPS_LONG}"
} > "${WORK}/list.expected"
check "a nested file, a dotfile, byte order, the stale list replaced and not listed" same_bytes "${LIST_DIR}/release_files.sha256" "${WORK}/list.expected"
check "no temporary file left behind" no_file "${LIST_DIR}/release_files.sha256.tmp"

echo "── rf_scripts_without_uid ──"
UID_DIR="${WORK}/uids"
mkdir -p "${UID_DIR}/commands" "${UID_DIR}/skills/deep/er" "${UID_DIR}/.dot"
printf 'x' > "${UID_DIR}/commands/has_uid.gd"
printf 'x' > "${UID_DIR}/commands/has_uid.gd.uid"
printf 'x' > "${UID_DIR}/commands/no_uid.gd"
printf 'x' > "${UID_DIR}/also_no_uid.gd"
printf '' > "${UID_DIR}/skills/.gdignore"
printf 'x' > "${UID_DIR}/skills/deep/er/exempt.gd"
printf 'x' > "${UID_DIR}/notes.txt"
check "names only the scanned scripts with no sidecar" equals "$(rf_scripts_without_uid "${UID_DIR}" | tr '\n' ' ')" "also_no_uid.gd commands/no_uid.gd "

echo "── rf_min_godot ──"
CRLF_ROOT="${WORK}/crlf/addons/godot_mcp_toolkit/versioning"
mkdir -p "${CRLF_ROOT}"
printf 'extends RefCounted\r\nconst GODOT_MIN_VERSION := "4.9"\r\n' > "${CRLF_ROOT}/mcp_version_utils.gd"
check "a CRLF copy gives the bare version" equals "$(rf_min_godot "${WORK}/crlf")" "4.9"

echo "── rf_write_manifest ──"
printf 'abc' > "${WORK}/godot-mcp-toolkit-1.2.0.zip"
rf_write_manifest "${WORK}/godot-mcp-toolkit-1.2.0.zip" "1.2.0" "4.2" "1.3.0" "1793000000" "${WORK}/manifest"
printf '{"format": 1, "version": "1.2.0", "archive": "godot-mcp-toolkit-1.2.0.zip", "archive_size": 3, "archive_sha256": "%s", "min_godot": "4.2", "compatible_server": "1.3.0", "expires_at": 1793000000}\n' "${HASH_ABC}" > "${WORK}/manifest.expected"
check "the exact bytes, trailing newline included" same_bytes "${WORK}/manifest" "${WORK}/manifest.expected"

echo "── rf_expires_at ──"
# A commit at a fixed time, with no files: the build reads only its time.
make_commit() {
  git -C "$1" init -q
  GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" \
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m fixture
}
mkdir -p "${WORK}/committed" "${WORK}/no-commit"
make_commit "${WORK}/committed"
git -C "${WORK}/no-commit" init -q
check "the commit time plus 180 days" equals "$(rf_expires_at "${WORK}/committed")" "1715552000"
run rf_expires_at "${WORK}/no-commit"
check "a repo with no commit fails" equals "${STATUS}" "1"

echo "── the build scripts ──"
# A repo the build scripts run in, holding the shapes the real addon has: a dotfile, a
# .gdignore folder with a script and no sidecar, a nested file, a script with one.
make_fixture_repo() {
  local repo="$1" addon="$1/addons/godot_mcp_toolkit"
  mkdir -p "${repo}/scripts/lib" "${addon}/CompanionSkills/references" "${addon}/nested/deep" "${addon}/versioning"
  cp "${REPO_ROOT}/scripts/build-plugin-release.sh" "${REPO_ROOT}/scripts/build-plugin-release.ps1" "${repo}/scripts/"
  cp "${REPO_ROOT}/scripts/lib/release_files.sh" "${REPO_ROOT}/scripts/lib/compatible_server.sh" "${repo}/scripts/lib/"
  printf 'abc' > "${addon}/.mcp.json.template"
  printf '' > "${addon}/CompanionSkills/.gdignore"
  printf 'hello\n' > "${addon}/CompanionSkills/references/example.gd"
  printf '%s' "${FIPS_LONG}" > "${addon}/nested/deep/data.txt"
  printf '[plugin]\nversion="1.2.0"\n' > "${addon}/plugin.cfg"
  printf 'const GODOT_MIN_VERSION := "4.9"\nconst COMPATIBLE_SERVER_VERSION := "9.8.7"\n' > "${addon}/versioning/mcp_version_utils.gd"
  printf 'uid://fixture\n' > "${addon}/versioning/mcp_version_utils.gd.uid"
  make_commit "${repo}"
}

# The fixture's three version files are hashed literally, taken with Python's hashlib
# rather than the code under test.
{
  printf '%s  .mcp.json.template\n' "${HASH_ABC}"
  printf '%s  CompanionSkills/.gdignore\n' "${HASH_EMPTY}"
  printf '%s  CompanionSkills/references/example.gd\n' "${HASH_HELLO}"
  printf '%s  nested/deep/data.txt\n' "${HASH_FIPS_LONG}"
  printf '84a201e46fbf2ada77918e59158e9b897cd58b196265864dbbe3d5eea06dbaf6  plugin.cfg\n'
  printf '6465f5d8e802576fff613abd1377ed44da1a14433a2eb220212a6db398000e40  versioning/mcp_version_utils.gd\n'
  printf '982e9eec5d00900cb2f11d8f7d48de45208d6450599edcc90a268d08c9d7616b  versioning/mcp_version_utils.gd.uid\n'
} > "${WORK}/build-list.expected"

ZIP_ENTRY="addons/godot_mcp_toolkit/release_files.sha256"

# Blanks the two values a zip's bytes decide, leaving what both builds must agree on.
manifest_without_zip_bytes() {
  sed -E 's/"archive_size": [0-9]+/"archive_size": SIZE/; s/"archive_sha256": "[0-9a-f]{64}"/"archive_sha256": "HASH"/' "$1"
}
printf '{"format": 1, "version": "1.2.0", "archive": "godot-mcp-toolkit-1.2.0.zip", "archive_size": SIZE, "archive_sha256": "HASH", "min_godot": "4.9", "compatible_server": "9.8.7", "expires_at": 1715552000}\n' > "${WORK}/build-manifest.expected"

# The entries the zip must hold, files only, whichever tool wrote it.
zip_files() {
  unzip -Z1 "$1" | grep -v '/$' | LC_ALL=C sort
}
{
  for entry in .mcp.json.template CompanionSkills/.gdignore CompanionSkills/references/example.gd \
    nested/deep/data.txt plugin.cfg release_files.sha256 versioning/mcp_version_utils.gd \
    versioning/mcp_version_utils.gd.uid; do
    printf 'addons/godot_mcp_toolkit/%s\n' "${entry}"
  done
} > "${WORK}/zip-files.expected"

# Hashes with openssl, a different tool from the one rf_sha256 calls.
openssl_sha256() {
  openssl dgst -sha256 < "$1" | sed -E 's/.*= *//' | tr -d '\r'
}
manifest_field() {
  sed -nE "s/.*\"$1\": *\"?([^\",}]*)\"?.*/\1/p" "$2"
}

# Checks one finished build: its manifest and its zip's list and file set.
check_built_release() {
  local name="$1" repo="$2"
  local zip="${repo}/dist-plugin/godot-mcp-toolkit-1.2.0.zip"
  local manifest="${repo}/dist-plugin/godot-mcp-toolkit-1.2.0.update.json"
  manifest_without_zip_bytes "${manifest}" > "${WORK}/${name}-manifest.actual"
  check "${name}: the manifest, zip bytes aside" same_bytes "${WORK}/${name}-manifest.actual" "${WORK}/build-manifest.expected"
  check "${name}: archive_size is the zip's" equals "$(manifest_field archive_size "${manifest}")" "$(file_size "${zip}")"
  check "${name}: archive_sha256 is the zip's" equals "$(manifest_field archive_sha256 "${manifest}")" "$(openssl_sha256 "${zip}")"
  unzip -p "${zip}" "${ZIP_ENTRY}" > "${WORK}/${name}-list.actual"
  check "${name}: the list, byte for byte, dotfiles included" same_bytes "${WORK}/${name}-list.actual" "${WORK}/build-list.expected"
  zip_files "${zip}" > "${WORK}/${name}-files.actual"
  check "${name}: the zip's forward-slash file set, dotfiles included" same_bytes "${WORK}/${name}-files.actual" "${WORK}/zip-files.expected"
}

make_fixture_repo "${WORK}/no-uid"
rm "${WORK}/no-uid/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd.uid"
run bash "${WORK}/no-uid/scripts/build-plugin-release.sh"
check "bash: a scanned script with no .uid is refused" equals "${STATUS}" "1"
check "bash: the refusal names it" contains "${OUT}" "versioning/mcp_version_utils.gd"
check "bash: the refusal does not name the .gdignore folder's script" lacks "${OUT}" "example.gd"
check "bash: no zip written" no_file "${WORK}/no-uid/dist-plugin/godot-mcp-toolkit-1.2.0.zip"

make_fixture_repo "${WORK}/no-commit-repo"
rm -rf "${WORK}/no-commit-repo/.git"
git -C "${WORK}/no-commit-repo" init -q
run bash "${WORK}/no-commit-repo/scripts/build-plugin-release.sh"
check "bash: no commit time is refused" equals "${STATUS}" "1"
check "bash: the refusal says so" contains "${OUT}" "commit time"

if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  make_fixture_repo "${WORK}/bash-build"
  run bash "${WORK}/bash-build/scripts/build-plugin-release.sh"
  check "bash: the build succeeds, with the .gdignore folder's script exempt" equals "${STATUS}" "0"
  check_built_release "bash" "${WORK}/bash-build"
else
  skip "bash: the full build needs zip and unzip"
fi

PS_RUNNER="${RELEASE_FILES_PS:-pwsh}"
run_ps1() {
  run "${PS_RUNNER}" -NoProfile -ExecutionPolicy Bypass -File "$1/scripts/build-plugin-release.ps1"
}
if command -v "${PS_RUNNER}" >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  make_fixture_repo "${WORK}/ps1-build"
  run_ps1 "${WORK}/ps1-build"
  check ".ps1: the build succeeds, with the .gdignore folder's script exempt" equals "${STATUS}" "0"
  check_built_release ".ps1" "${WORK}/ps1-build"

  make_fixture_repo "${WORK}/ps1-no-uid"
  rm "${WORK}/ps1-no-uid/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd.uid"
  run_ps1 "${WORK}/ps1-no-uid"
  check ".ps1: a scanned script with no .uid is refused" equals "${STATUS}" "1"
  check ".ps1: the refusal names it" contains "${OUT}" "versioning/mcp_version_utils.gd"
  check ".ps1: the refusal does not name the .gdignore folder's script" lacks "${OUT}" "example.gd"

  make_fixture_repo "${WORK}/ps1-no-commit"
  rm -rf "${WORK}/ps1-no-commit/.git"
  git -C "${WORK}/ps1-no-commit" init -q
  run_ps1 "${WORK}/ps1-no-commit"
  check ".ps1: no commit time is refused" equals "${STATUS}" "1"
else
  skip ".ps1: the half needs ${PS_RUNNER} and unzip"
fi

echo "── sign-release.sh ──"
SIGN="${REPO_ROOT}/scripts/sign-release.sh"
KEYS="${WORK}/keys"
SIGNING="${WORK}/signing"
SIG_NAME="godot-mcp-toolkit-1.2.0.update.json.sig"
PASSPHRASE="fixture-passphrase"
UNUSED_LINE="a line a plain key does not need"
mkdir -p "${KEYS}" "${SIGNING}"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/plain.pem" 2>/dev/null
openssl pkey -in "${KEYS}/plain.pem" -pubout -out "${KEYS}/plain.pub.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -pass "pass:${PASSPHRASE}" -out "${KEYS}/encrypted.pem" 2>/dev/null
openssl pkey -in "${KEYS}/encrypted.pem" -passin "pass:${PASSPHRASE}" -pubout -out "${KEYS}/encrypted.pub.pem" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "${KEYS}/ec.pem" 2>/dev/null
openssl pkey -in "${KEYS}/ec.pem" -pubout -out "${KEYS}/ec.pub.pem" 2>/dev/null

# Gives a new folder a manifest; $2 is the manifest's file name there.
make_signing_case() {
  mkdir -p "${SIGNING}/$1"
  cp "${WORK}/manifest.expected" "${SIGNING}/$1/$2"
}
# Runs sign-release.sh with the line $1 piped to its stdin.
sign_piped() {
  local stdin_line="$1"
  shift
  OUT="$(bash "${SIGN}" "$@" 2>&1 < <(printf '%s\n' "${stdin_line}"))" && STATUS=0 || STATUS=$?
}

make_signing_case plain "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem" "${KEYS}/plain.pub.pem"
check "plain key through the pipe: signed" equals "${STATUS}" "0"
check "plain key: the .sig verifies with openssl directly" verifies "${KEYS}/plain.pub.pem" "${SIGNING}/plain/${SIG_NAME}" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
check "plain key: the raw 256-byte signature of an RSA-2048 key" equals "$(file_size "${SIGNING}/plain/${SIG_NAME}")" "256"
check "plain key: the output says to upload to the draft" contains "${OUT}" "draft before publishing"

make_signing_case encrypted "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${PASSPHRASE}" "${SIGNING}/encrypted/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem" "${KEYS}/encrypted.pub.pem"
check "encrypted key through a pipe: signed" equals "${STATUS}" "0"
check "encrypted key: the .sig verifies with openssl directly" verifies "${KEYS}/encrypted.pub.pem" "${SIGNING}/encrypted/${SIG_NAME}" "${SIGNING}/encrypted/godot-mcp-toolkit-1.2.0.update.json"

make_signing_case wrong-pass "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "not-the-passphrase" "${SIGNING}/wrong-pass/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem" "${KEYS}/encrypted.pub.pem"
check "the wrong passphrase fails" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"
check "the wrong passphrase leaves no .sig" no_file "${SIGNING}/wrong-pass/${SIG_NAME}"

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
private_key_reads() {
  if [[ -f "${OPENSSL_LOG}" ]]; then
    grep -c -F "$1" "${OPENSSL_LOG}" || true
  else
    echo 0
  fi
}

make_signing_case once "godot-mcp-toolkit-1.2.0.update.json"
PATH="${WORK}/stub:${ORIGINAL_PATH}"
sign_piped "${PASSPHRASE}" "${SIGNING}/once/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem" "${KEYS}/encrypted.pub.pem"
PATH="${ORIGINAL_PATH}"
check "the private key is read exactly once" equals "$(private_key_reads "${KEYS}/encrypted.pem")" "1"

make_signing_case ec "godot-mcp-toolkit-1.2.0.update.json"
rm -f "${OPENSSL_LOG}"
PATH="${WORK}/stub:${ORIGINAL_PATH}"
sign_piped "${UNUSED_LINE}" "${SIGNING}/ec/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/ec.pem" "${KEYS}/ec.pub.pem"
PATH="${ORIGINAL_PATH}"
check "an EC key is refused" equals "${STATUS}" "1"
check "the refusal says RSA" contains "${OUT}" "not an RSA key"
check "the refusal comes before the private key is read" equals "$(private_key_reads "${KEYS}/ec.pem")" "0"
check "the refusal leaves no .sig" no_file "${SIGNING}/ec/${SIG_NAME}"

make_signing_case mismatched "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/mismatched/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem" "${KEYS}/encrypted.pub.pem"
check "another key's public half fails" equals "${STATUS}" "1"
check "the failure leaves no .sig" no_file "${SIGNING}/mismatched/${SIG_NAME}"
check "the failure leaves no temporary file" no_file "${SIGNING}/mismatched/${SIG_NAME}.tmp"

make_signing_case renamed "some-other-name.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pem" "${KEYS}/plain.pub.pem"
check "a manifest under another path: signed" equals "${STATUS}" "0"
check "the .sig takes its name from the version" is_file "${SIGNING}/renamed/${SIG_NAME}"
check "the .sig does not take its name from the path" no_file "${SIGNING}/renamed/some-other-name.json.sig"
run bash "${SIGN}" --verify "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pub.pem"
check "--verify finds it under that same name" equals "${STATUS}" "0"

make_signing_case no-version "godot-mcp-toolkit-1.2.0.update.json"
printf '{"format": 1, "version": "../../evil"}\n' > "${SIGNING}/no-version/godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/no-version/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem" "${KEYS}/plain.pub.pem"
check "a version that is no version is refused" equals "${STATUS}" "1"

run bash "${SIGN}" --verify "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pub.pem"
check "--verify accepts the signed manifest" equals "${STATUS}" "0"
sed 's/"archive_size": 3/"archive_size": 4/' "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" > "${SIGNING}/plain/changed.tmp"
mv "${SIGNING}/plain/changed.tmp" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
run bash "${SIGN}" --verify "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pub.pem"
check "--verify rejects a one-byte change" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"

run bash "${SIGN}" --key-entry "${KEYS}/plain.pub.pem"
ENTRY="${OUT}"
check "--key-entry prints one line" equals "$(printf '%s\n' "${ENTRY}" | wc -l | tr -d ' ')" "1"
check "--key-entry opens a quoted escaped PEM" contains "${ENTRY}" '"-----BEGIN PUBLIC KEY-----\n'
check "--key-entry closes it" contains "${ENTRY}" '-----END PUBLIC KEY-----\n"'
printf '%b' "$(printf '%s' "${ENTRY}" | tr -d '"')" > "${WORK}/entry.pem"
tr -d '\r' < "${KEYS}/plain.pub.pem" > "${WORK}/plain.lf.pem"
check "--key-entry unescapes to the key" same_bytes "${WORK}/entry.pem" "${WORK}/plain.lf.pem"
run bash "${SIGN}" --help
check "the usage does not say where keys live" lacks "${OUT}" "PUBLIC_KEYS"
check "the usage names the three-argument form" contains "${OUT}" "<manifest> <private-key.pem> <public-key.pem>"
run bash "${SIGN}" "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pem"
check "two arguments no longer sign" equals "${STATUS}" "2"

echo "── check_release_files.sh ──"
CHECK="${REPO_ROOT}/scripts/check_release_files.sh"
CASES="${WORK}/cases"
BASE="${CASES}/base"
mkdir -p "${BASE}/tree/commands"
printf 'abc' > "${BASE}/godot-mcp-toolkit-1.2.0.zip"
printf '[plugin]\nversion="1.2.0"\n' > "${BASE}/tree/plugin.cfg"
printf 'extends RefCounted\n' > "${BASE}/tree/commands/a.gd"
printf 'uid://a\n' > "${BASE}/tree/commands/a.gd.uid"
printf '' > "${BASE}/tree/.hidden"
rf_write_list "${BASE}/tree"

# Writes a case's manifest: size, hash, version and archive, in that order.
write_case_manifest() {
  printf '{"format": 1, "version": "%s", "archive": "%s", "archive_size": %s, "archive_sha256": "%s", "min_godot": "4.2", "compatible_server": "1.2.0", "expires_at": 1793000000}\n' \
    "$4" "$5" "$2" "$3" > "$1/manifest.json"
}
write_case_manifest "${BASE}" 3 "${HASH_ABC}" 1.2.0 godot-mcp-toolkit-1.2.0.zip

new_case() {
  cp -R "${BASE}" "${CASES}/$1"
}
run_case() {
  run bash "${CHECK}" "${CASES}/$1/godot-mcp-toolkit-1.2.0.zip" "${CASES}/$1/manifest.json" "${CASES}/$1/tree"
}

new_case clean
run_case clean
check "a clean release passes" equals "${STATUS}" "0"

new_case booted
printf 'engine state\n' > "${CASES}/booted/tree/icon.svg.import"
run_case booted
check "the engine's *.import is allowed" equals "${STATUS}" "0"

new_case tampered
printf 'x' >> "${CASES}/tampered/tree/commands/a.gd"
run_case tampered
check "a tampered file fails" equals "${STATUS}" "1"
check "its report names the file" contains "${OUT}" "commands/a.gd"

new_case missing
rm "${CASES}/missing/tree/commands/a.gd"
run_case missing
check "a listed file gone fails" equals "${STATUS}" "1"

new_case extra
printf 'written at runtime\n' > "${CASES}/extra/tree/commands/stray.cfg"
run_case extra
check "an unlisted file fails" equals "${STATUS}" "1"
check "its report names the file" contains "${OUT}" "commands/stray.cfg"

new_case minted
printf 'uid://minted\n' > "${CASES}/minted/tree/commands/b.gd.uid"
run_case minted
check "a .uid the engine minted fails" equals "${STATUS}" "1"
check "its report names the file" contains "${OUT}" "commands/b.gd.uid"

new_case no-list
rm "${CASES}/no-list/tree/release_files.sha256"
run_case no-list
check "a tree with no list fails" equals "${STATUS}" "1"

new_case wrong-hash
write_case_manifest "${CASES}/wrong-hash" 3 "${HASH_HELLO}" 1.2.0 godot-mcp-toolkit-1.2.0.zip
run_case wrong-hash
check "a wrong hash fails" equals "${STATUS}" "1"
check "its report names archive_sha256" contains "${OUT}" "archive_sha256 is '${HASH_HELLO}'"

new_case wrong-size
write_case_manifest "${CASES}/wrong-size" 4 "${HASH_ABC}" 1.2.0 godot-mcp-toolkit-1.2.0.zip
run_case wrong-size
check "a wrong size fails" equals "${STATUS}" "1"
check "its report names archive_size" contains "${OUT}" "archive_size is '4'"

new_case wrong-version
write_case_manifest "${CASES}/wrong-version" 3 "${HASH_ABC}" 1.2.1 godot-mcp-toolkit-1.2.0.zip
run_case wrong-version
check "a wrong version fails" equals "${STATUS}" "1"
check "its report names the version" contains "${OUT}" "version is '1.2.1'"

new_case tree-version
printf '[plugin]\nversion="1.1.9"\n' > "${CASES}/tree-version/tree/plugin.cfg"
rf_write_list "${CASES}/tree-version/tree"
run_case tree-version
check "a plugin.cfg of another version fails" equals "${STATUS}" "1"

new_case wrong-archive
write_case_manifest "${CASES}/wrong-archive" 3 "${HASH_ABC}" 1.2.0 other.zip
run_case wrong-archive
check "another archive name fails" equals "${STATUS}" "1"

new_case tampered-zip
printf 'abd' > "${CASES}/tampered-zip/godot-mcp-toolkit-1.2.0.zip"
run_case tampered-zip
check "a zip changed after the manifest fails on its hash" contains "${OUT}" "archive_sha256 is '${HASH_ABC}'"

run bash "${CHECK}" only-one-argument
check "a wrong call is a setup error" equals "${STATUS}" "2"

if [[ -f "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.zip" ]]; then
  mkdir -p "${WORK}/unzipped"
  unzip -q "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.zip" -d "${WORK}/unzipped"
  run bash "${CHECK}" "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.zip" \
    "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.update.json" \
    "${WORK}/unzipped/addons/godot_mcp_toolkit"
  check "the bash build's own output passes" equals "${STATUS}" "0"
else
  skip "the check against a real build needs the full build"
fi

echo ""
if [[ ${FAILED} -eq 0 ]]; then
  echo "PASS: ${PASSED} checks, ${SKIPPED} skipped"
  exit 0
fi
echo "FAIL: ${FAILED} of $((PASSED + FAILED)) checks failed, ${SKIPPED} skipped"
exit 1
