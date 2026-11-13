#!/usr/bin/env bash
# scripts/test_release_files.sh
# Tests the files a release publishes and the scripts around them, with no network, no
# Godot and no change to the repo. Fixtures and keys are generated at run time, so line
# endings in a checkout cannot move a pinned hash, and no key lives in the repo:
#   - scripts/lib/release_files.sh against known SHA-256 vectors and a fixed manifest;
#   - both build scripts on a fixture repo: the missing .uid and the unreadable commit
#     time refused, the list and manifest pinned, the .ps1 matching them and ASCII; the
#     bash build also refusing an unreadable Godot floor or server pin;
#   - scripts/sign-release.sh in a tagged repo made here, with stand-ins for gh and
#     sleep: plain, encrypted, unlisted and non-RSA keys, the draft's digest, and the
#     trust document at the tag;
#   - scripts/check_release_files.sh's failures, on real zips.
#
# The real builds need zip, unzip and pwsh, the check's cases need zip and unzip, and the
# RSA-PSS case needs an openssl that makes such a key; those checks say "skip" without
# them. RELEASE_FILES_REQUIRE_ALL=1 turns a skip into a failure; RELEASE_FILES_PS names
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
mkdir -p "${UID_DIR}/commands" "${UID_DIR}/skills/deep/er"
printf 'x' > "${UID_DIR}/commands/has_uid.gd"
printf 'x' > "${UID_DIR}/commands/has_uid.gd.uid"
printf 'x' > "${UID_DIR}/commands/no_uid.gd"
printf 'x' > "${UID_DIR}/also_no_uid.gd"
printf '' > "${UID_DIR}/skills/.gdignore"
printf 'x' > "${UID_DIR}/skills/deep/er/exempt.gd"
printf 'x' > "${UID_DIR}/notes.txt"
check "names only the scanned scripts with no sidecar" equals "$(rf_scripts_without_uid "${UID_DIR}" | tr '\n' ' ')" "also_no_uid.gd commands/no_uid.gd "
UID_IGNORED_ROOT="${WORK}/uids-ignored-root"
mkdir -p "${UID_IGNORED_ROOT}/deep"
printf '' > "${UID_IGNORED_ROOT}/.gdignore"
printf 'x' > "${UID_IGNORED_ROOT}/top.gd"
printf 'x' > "${UID_IGNORED_ROOT}/deep/nested.gd"
check "a .gdignore at the folder's root exempts every script" equals "$(rf_scripts_without_uid "${UID_IGNORED_ROOT}")" ""

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

# The fixture's three version files are hashed literally: known SHA-256 vectors, like
# the others.
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

# The entries the zip must hold, files only, whichever tool wrote it. An unreadable zip
# gives an empty set, for the comparison to report.
zip_files() {
  { unzip -Z1 "$1" || true; } | { grep -v '/$' || true; } | LC_ALL=C sort
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

# Checks one finished build: its manifest and its zip's list and file set. A build that
# wrote neither is a failed check here, so the suite still finishes and reports.
check_built_release() {
  local name="$1" repo="$2"
  local zip="${repo}/dist-plugin/godot-mcp-toolkit-1.2.0.zip"
  local manifest="${repo}/dist-plugin/godot-mcp-toolkit-1.2.0.update.json"
  check "${name}: the build wrote the zip" is_file "${zip}"
  check "${name}: the build wrote the manifest" is_file "${manifest}"
  [[ -f "${zip}" && -f "${manifest}" ]] || return 0
  manifest_without_zip_bytes "${manifest}" > "${WORK}/${name}-manifest.actual"
  check "${name}: the manifest, zip bytes aside" same_bytes "${WORK}/${name}-manifest.actual" "${WORK}/build-manifest.expected"
  check "${name}: archive_size is the zip's" equals "$(manifest_field archive_size "${manifest}")" "$(file_size "${zip}")"
  check "${name}: archive_sha256 is the zip's" equals "$(manifest_field archive_sha256 "${manifest}")" "$(openssl_sha256 "${zip}")"
  unzip -p "${zip}" "${ZIP_ENTRY}" > "${WORK}/${name}-list.actual" || true
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

make_fixture_repo "${WORK}/no-floor"
printf 'const COMPATIBLE_SERVER_VERSION := "9.8.7"\n' > "${WORK}/no-floor/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd"
run bash "${WORK}/no-floor/scripts/build-plugin-release.sh"
check "bash: an unreadable Godot floor is refused" equals "${STATUS}" "1"
check "bash: the refusal names the constant" contains "${OUT}" "GODOT_MIN_VERSION"
check "bash: no manifest written for an unreadable floor" no_file "${WORK}/no-floor/dist-plugin/godot-mcp-toolkit-1.2.0.update.json"

make_fixture_repo "${WORK}/no-server"
printf 'const GODOT_MIN_VERSION := "4.9"\n' > "${WORK}/no-server/addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd"
run bash "${WORK}/no-server/scripts/build-plugin-release.sh"
check "bash: an unreadable server pin is refused" equals "${STATUS}" "1"
check "bash: the refusal names the constant" contains "${OUT}" "COMPATIBLE_SERVER_VERSION"
check "bash: no manifest written for an unreadable server pin" no_file "${WORK}/no-server/dist-plugin/godot-mcp-toolkit-1.2.0.update.json"

# Windows PowerShell 5.1 reads a script with no BOM in the system code page, where a
# UTF-8 dash can end a string early. pwsh reads UTF-8 and parses the same file, so the
# .ps1 half running green does not rule one out.
non_ascii_bytes() {
  LC_ALL=C tr -d '\11\12\15\40-\176' < "$1" | wc -c | tr -d ' '
}
check ".ps1: every byte is ASCII" equals "$(non_ascii_bytes "${REPO_ROOT}/scripts/build-plugin-release.ps1")" "0"

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
SIGN_REPO="${WORK}/sign-repo"
TRUST_TOOL="${REPO_ROOT}/scripts/trust-document.sh"
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
# A root for the fixture's trust documents, and a release key none of them lists.
for name in root unlisted; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/${name}.pem" 2>/dev/null
  openssl pkey -in "${KEYS}/${name}.pem" -pubout -out "${KEYS}/${name}.pub.pem" 2>/dev/null
done

# Commits the fixture repo's trust folder, if it has one yet, and tags that commit $1.
tag_sign_repo() {
  [[ ! -d "${SIGN_REPO}/trust" ]] || git -C "${SIGN_REPO}" -c core.autocrlf=false add trust
  git -C "${SIGN_REPO}" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m "$1"
  git -C "${SIGN_REPO}" -c tag.gpgsign=false tag "$1"
}

# Three tags: v1.1.0 with no trust document, v1.2.0 with trust-1 listing the plain and
# the encrypted key, and v1.2.1 with trust-2 added, which drops the plain key. The
# documents are unsigned: sign-release.sh reads a document's release keys and leaves its
# signatures to trust-document.sh verify.
mkdir -p "${SIGN_REPO}"
git -C "${SIGN_REPO}" init -q
tag_sign_repo v1.1.0
mkdir -p "${SIGN_REPO}/trust"
bash "${TRUST_TOOL}" build --first --add-root "${KEYS}/root.pub.pem" \
  --add-release "${KEYS}/plain.pub.pem" --add-release "${KEYS}/encrypted.pub.pem" --out "${SIGN_REPO}/trust" >/dev/null
tag_sign_repo v1.2.0
bash "${TRUST_TOOL}" build "${SIGN_REPO}/trust/trust-1.json" --drop-release "${KEYS}/plain.pub.pem" >/dev/null
tag_sign_repo v1.2.1
# sign-release.sh reads the tags of the checkout it sits in. git reads GIT_DIR before the
# folder it is pointed at, so until the unset below those reads land in the repo above.
export GIT_DIR="${SIGN_REPO}/.git"

# Stand-ins for the two tools signing waits on: a gh, named by GH_BIN, that answers the
# two reads sign-release.sh makes from files a case writes with set_draft, and a sleep on
# the PATH that only counts.
SYSTEM_PATH="${PATH}"
export GH_BIN="${WORK}/gh-stand-in/gh"
export DRAFT="${WORK}/draft"
mkdir -p "${WORK}/tools" "${WORK}/gh-stand-in" "${DRAFT}"
cat > "${WORK}/gh-stand-in/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DRAFT}/gh.log"
[[ "$1" == "api" ]] || exit 1
case "$2" in
  "repos/{owner}/{repo}/releases")
    cat "${DRAFT}/ids"
    ;;
  "repos/{owner}/{repo}/releases/"*"/assets")
    # One line of the digests per read; the last line answers every read after it.
    reads="$(( $(cat "${DRAFT}/reads") + 1 ))"
    printf '%s\n' "${reads}" > "${DRAFT}/reads"
    lines="$(wc -l < "${DRAFT}/digests" | tr -d ' ')"
    sed -n "$(( reads < lines ? reads : lines ))p" "${DRAFT}/digests"
    ;;
  *)
    exit 1
    ;;
esac
STUB
cat > "${WORK}/tools/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${DRAFT}/sleep.log"
STUB
chmod +x "${WORK}/gh-stand-in/gh" "${WORK}/tools/sleep"
PATH="${WORK}/tools:${PATH}"

# Sets what GitHub answers from here on: $1 is the id of each draft tagged for the
# release, a line each, and the arguments after it are the manifest asset's digest at
# each read, the last one repeating.
set_draft() {
  local ids="$1"
  shift
  printf '%s\n' "${ids}" > "${DRAFT}/ids"
  printf '%s\n' "$@" > "${DRAFT}/digests"
  echo 0 > "${DRAFT}/reads"
  rm -f "${DRAFT}/gh.log" "${DRAFT}/sleep.log"
}
log_lines() {
  if [[ -f "$1" ]]; then
    wc -l < "$1" | tr -d ' '
  else
    echo 0
  fi
}

# Gives a new folder a manifest; $2 is the manifest's file name there.
make_signing_case() {
  mkdir -p "${SIGNING}/$1"
  cp "${WORK}/manifest.expected" "${SIGNING}/$1/$2"
}
# Gives a new folder the manifest of another version, $2, under that version's name.
make_versioned_case() {
  mkdir -p "${SIGNING}/$1"
  sed "s/\"version\": \"1.2.0\"/\"version\": \"$2\"/" "${WORK}/manifest.expected" > "${SIGNING}/$1/godot-mcp-toolkit-$2.update.json"
}
# Runs sign-release.sh with the line $1 piped to its stdin.
sign_piped() {
  local stdin_line="$1"
  shift
  OUT="$(bash "${SIGN}" "$@" 2>&1 < <(printf '%s\n' "${stdin_line}"))" && STATUS=0 || STATUS=$?
}

MANIFEST_DIGEST="sha256:$(openssl_sha256 "${WORK}/manifest.expected")"
set_draft 42 "${MANIFEST_DIGEST}"

make_signing_case plain "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem"
check "plain key through the pipe: signed" equals "${STATUS}" "0"
check "plain key: the .sig verifies with openssl directly" verifies "${KEYS}/plain.pub.pem" "${SIGNING}/plain/${SIG_NAME}" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
check "plain key: the raw 256-byte signature of an RSA-2048 key" equals "$(file_size "${SIGNING}/plain/${SIG_NAME}")" "256"
check "plain key: the output says to attach it to the draft" contains "${OUT}" "Attach it to the draft"
check "plain key: the attach command names the manifest's version" contains "${OUT}" "scripts/publish-release.sh attach v1.2.0"
check "plain key: the manifest's SHA-256 is printed" contains "${OUT}" "the manifest here       ${MANIFEST_DIGEST}"
check "plain key: the draft's digest is printed beside it" contains "${OUT}" "the draft's manifest    ${MANIFEST_DIGEST}"
check "plain key: the assets read names the draft's id" contains "$(cat "${DRAFT}/gh.log")" "repos/{owner}/{repo}/releases/42/assets"

make_signing_case encrypted "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${PASSPHRASE}" "${SIGNING}/encrypted/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem"
check "encrypted key through a pipe: signed" equals "${STATUS}" "0"
check "encrypted key: the .sig verifies with openssl directly" verifies "${KEYS}/encrypted.pub.pem" "${SIGNING}/encrypted/${SIG_NAME}" "${SIGNING}/encrypted/godot-mcp-toolkit-1.2.0.update.json"

make_signing_case wrong-pass "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "not-the-passphrase" "${SIGNING}/wrong-pass/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem"
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
sign_piped "${PASSPHRASE}" "${SIGNING}/once/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/encrypted.pem"
PATH="${ORIGINAL_PATH}"
check "the private key is read exactly once" equals "$(private_key_reads "${KEYS}/encrypted.pem")" "1"

make_signing_case ec "godot-mcp-toolkit-1.2.0.update.json"
rm -f "${OPENSSL_LOG}"
PATH="${WORK}/stub:${ORIGINAL_PATH}"
sign_piped "${UNUSED_LINE}" "${SIGNING}/ec/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/ec.pem"
PATH="${ORIGINAL_PATH}"
check "an EC key is refused" equals "${STATUS}" "1"
check "the refusal says RSA" contains "${OUT}" "not an RSA key"
check "the refusal comes at the one read of the private key" equals "$(private_key_reads "${KEYS}/ec.pem")" "1"
check "the refusal leaves no .sig" no_file "${SIGNING}/ec/${SIG_NAME}"

# An RSA-PSS key prints a modulus like a plain RSA key, but signs with another padding.
# An openssl may not make such a key, or may not print one.
if openssl genpkey -algorithm RSA-PSS -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/pss.pem" 2>/dev/null \
  && openssl pkey -in "${KEYS}/pss.pem" -pubout -out "${KEYS}/pss.pub.pem" 2>/dev/null \
  && openssl pkey -pubin -in "${KEYS}/pss.pub.pem" -noout -text >/dev/null 2>&1; then
  make_signing_case pss "godot-mcp-toolkit-1.2.0.update.json"
  sign_piped "${UNUSED_LINE}" "${SIGNING}/pss/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/pss.pem"
  check "an RSA-PSS key is refused" equals "${STATUS}" "1"
  check "the RSA-PSS refusal says RSA" contains "${OUT}" "not an RSA key"
  check "the RSA-PSS refusal leaves no .sig" no_file "${SIGNING}/pss/${SIG_NAME}"
else
  skip "the RSA-PSS case needs an openssl that makes and prints such a key"
fi

make_signing_case unlisted "godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/unlisted/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/unlisted.pem"
check "a key that is no release key of the document at the tag fails" equals "${STATUS}" "1"
check "the failure leaves no .sig" no_file "${SIGNING}/unlisted/${SIG_NAME}"
check "the failure leaves no temporary file" no_file "${SIGNING}/unlisted/${SIG_NAME}.tmp"
check "the failure names the document and its tag" contains "${OUT}" "none of the 2 release keys of trust-1.json at v1.2.0"

make_signing_case renamed "some-other-name.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pem"
check "a manifest under another path: signed" equals "${STATUS}" "0"
check "the .sig takes its name from the version" is_file "${SIGNING}/renamed/${SIG_NAME}"
check "the .sig does not take its name from the path" no_file "${SIGNING}/renamed/some-other-name.json.sig"
run bash "${SIGN}" --verify "${SIGNING}/renamed/some-other-name.json"
check "--verify finds it under that same name" equals "${STATUS}" "0"

make_signing_case no-version "godot-mcp-toolkit-1.2.0.update.json"
printf '{"format": 1, "version": "../../evil"}\n' > "${SIGNING}/no-version/godot-mcp-toolkit-1.2.0.update.json"
sign_piped "${UNUSED_LINE}" "${SIGNING}/no-version/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem"
check "a version that is no version is refused" equals "${STATUS}" "1"
check "the refusal says the version is the problem" contains "${OUT}" "no usable version"

run bash "${SIGN}" --verify "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
check "--verify accepts the signed manifest" equals "${STATUS}" "0"
sed 's/"archive_size": 3/"archive_size": 4/' "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json" > "${SIGNING}/plain/changed.tmp"
mv "${SIGNING}/plain/changed.tmp" "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
run bash "${SIGN}" --verify "${SIGNING}/plain/godot-mcp-toolkit-1.2.0.update.json"
check "--verify rejects a one-byte change" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"

run bash "${SIGN}" --help
check "the usage does not say where keys live" lacks "${OUT}" "embedded_trust_document"
check "the usage names the two-argument form" contains "${OUT}" "scripts/sign-release.sh <manifest> <private-key.pem>"
check "the usage names no public key to pass" lacks "${OUT}" "<public-key.pem>"
run bash "${SIGN}" "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pem" "${KEYS}/plain.pub.pem"
check "a third argument is wrong usage" equals "${STATUS}" "2"
run bash "${SIGN}" "${SIGNING}/renamed/some-other-name.json"
check "a manifest with no key is wrong usage" equals "${STATUS}" "2"
run bash "${SIGN}" "${SIGNING}/renamed/some-other-name.json" "${KEYS}/no-such-key.pem"
check "a key file that is not there is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no key at"
run bash "${SIGN}" --key-entry "${KEYS}/plain.pub.pem"
check "--key-entry is not a command" equals "${STATUS}" "2"
run bash "${SIGN}" --verify "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pub.pem"
check "--verify takes no public key" equals "${STATUS}" "2"

echo "── sign-release.sh: the trust document at the tag ──"
run bash "${SIGN}" --verify "${SIGNING}/encrypted/godot-mcp-toolkit-1.2.0.update.json"
check "--verify accepts a .sig by the document's second release key" equals "${STATUS}" "0"
run bash "${SIGN}" --verify "${SIGNING}/wrong-pass/godot-mcp-toolkit-1.2.0.update.json"
check "--verify with no .sig is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no signature at"

# A signature by the unlisted key, made without the script, so --verify alone is what
# refuses it.
openssl dgst -sha256 -sign "${KEYS}/unlisted.pem" -out "${SIGNING}/unlisted/${SIG_NAME}" "${SIGNING}/unlisted/godot-mcp-toolkit-1.2.0.update.json" </dev/null
run bash "${SIGN}" --verify "${SIGNING}/unlisted/godot-mcp-toolkit-1.2.0.update.json"
check "--verify refuses a .sig by a key the document does not list" equals "${STATUS}" "1"
check "that refusal names the document" contains "${OUT}" "none of the 2 release keys of trust-1.json at v1.2.0"

# v1.2.1's newest document is trust-2, which dropped the plain key.
make_versioned_case newer 1.2.1
set_draft 42 "sha256:$(openssl_sha256 "${SIGNING}/newer/godot-mcp-toolkit-1.2.1.update.json")"
sign_piped "${UNUSED_LINE}" "${SIGNING}/newer/godot-mcp-toolkit-1.2.1.update.json" "${KEYS}/plain.pem"
check "a key the tag's newest document dropped is refused" equals "${STATUS}" "1"
check "that refusal names the newest document" contains "${OUT}" "none of the 1 release keys of trust-2.json at v1.2.1"
sign_piped "${PASSPHRASE}" "${SIGNING}/newer/godot-mcp-toolkit-1.2.1.update.json" "${KEYS}/encrypted.pem"
check "the key that document keeps signs" equals "${STATUS}" "0"
run bash "${SIGN}" --verify "${SIGNING}/renamed/some-other-name.json"
check "an older release still verifies against the document at its own tag" equals "${STATUS}" "0"

make_versioned_case no-document 1.1.0
sign_piped "${UNUSED_LINE}" "${SIGNING}/no-document/godot-mcp-toolkit-1.1.0.update.json" "${KEYS}/plain.pem"
check "a tag with no trust document is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "holds no trust document"
make_versioned_case no-tag 9.9.9
sign_piped "${UNUSED_LINE}" "${SIGNING}/no-tag/godot-mcp-toolkit-9.9.9.update.json" "${KEYS}/plain.pem"
check "a version with no tag is refused" equals "${STATUS}" "1"
check "that refusal names the tag" contains "${OUT}" "no tag v9.9.9"

echo "── sign-release.sh: the draft's digest ──"
# Signs the case $1's manifest with the plain key, counting the reads of that key.
sign_draft_case() {
  make_signing_case "$1" "godot-mcp-toolkit-1.2.0.update.json"
  rm -f "${OPENSSL_LOG}"
  PATH="${WORK}/stub:${ORIGINAL_PATH}"
  sign_piped "${UNUSED_LINE}" "${SIGNING}/$1/godot-mcp-toolkit-1.2.0.update.json" "${KEYS}/plain.pem"
  PATH="${ORIGINAL_PATH}"
}

set_draft 42 "sha256:${HASH_HELLO}"
sign_draft_case other-manifest
check "a draft holding another manifest is refused" equals "${STATUS}" "1"
check "that refusal shows the manifest's SHA-256" contains "${OUT}" "the manifest here       ${MANIFEST_DIGEST}"
check "that refusal shows the draft's digest beside it" contains "${OUT}" "the draft's manifest    sha256:${HASH_HELLO}"
check "that refusal comes before the private key is read" equals "$(private_key_reads "${KEYS}/plain.pem")" "0"
check "that refusal leaves no .sig" no_file "${SIGNING}/other-manifest/${SIG_NAME}"

set_draft "" "${MANIFEST_DIGEST}"
sign_draft_case no-draft
check "no draft for the tag is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no draft release for v1.2.0"
check "that refusal comes before the private key is read" equals "$(private_key_reads "${KEYS}/plain.pem")" "0"

set_draft $'41\n42' "${MANIFEST_DIGEST}"
sign_draft_case two-drafts
check "two drafts for the tag are refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "more than one draft release"

set_draft 42 ""
sign_draft_case no-digest
check "a digest that stays empty is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "reports no digest"
check "the digest is read five times" equals "$(cat "${DRAFT}/reads")" "5"
check "with four waits between the reads" equals "$(log_lines "${DRAFT}/sleep.log")" "4"
check "that refusal comes before the private key is read" equals "$(private_key_reads "${KEYS}/plain.pem")" "0"

set_draft 42 "" "" "${MANIFEST_DIGEST}"
sign_draft_case late-digest
check "a digest GitHub fills in late: signed" equals "${STATUS}" "0"
check "after two waits" equals "$(log_lines "${DRAFT}/sleep.log")" "2"
check "the .sig verifies with openssl directly" verifies "${KEYS}/plain.pub.pem" "${SIGNING}/late-digest/${SIG_NAME}" "${SIGNING}/late-digest/godot-mcp-toolkit-1.2.0.update.json"

rm "${DRAFT}/ids"
sign_draft_case gh-fails
check "a failed read of GitHub is refused" equals "${STATUS}" "1"
check "that refusal leaves no .sig" no_file "${SIGNING}/gh-fails/${SIG_NAME}"

unset GIT_DIR GH_BIN
PATH="${SYSTEM_PATH}"

echo "── check_release_files.sh ──"
CHECK="${REPO_ROOT}/scripts/check_release_files.sh"
CASES="${WORK}/cases"
BASE="${CASES}/base"
CASE_ZIP="godot-mcp-toolkit-1.2.0.zip"

# Zips a case's tree as $2, under the path a release's zip uses.
zip_case() {
  mkdir -p "$1/stage/addons"
  cp -R "$1/tree" "$1/stage/addons/godot_mcp_toolkit"
  rm -f "$1/$2"
  (cd "$1/stage" && zip -qr "../$2" addons)
  rm -rf "$1/stage"
}
# Writes a case's manifest: size, hash, version and archive, in that order.
write_case_manifest() {
  printf '{"format": 1, "version": "%s", "archive": "%s", "archive_size": %s, "archive_sha256": "%s", "min_godot": "4.2", "compatible_server": "1.2.0", "expires_at": 1793000000}\n' \
    "$4" "$5" "$2" "$3" > "$1/manifest.json"
}
# Writes a manifest true to the case's zip $2, at version $3.
write_true_manifest() {
  write_case_manifest "$1" "$(file_size "$1/$2")" "$(openssl_sha256 "$1/$2")" "$3" "$2"
}
new_case() {
  cp -R "${BASE}" "${CASES}/$1"
}
run_case() {
  run bash "${CHECK}" "${CASES}/$1/${CASE_ZIP}" "${CASES}/$1/manifest.json" "${CASES}/$1/tree"
}

run bash "${CHECK}" only-one-argument
check "a wrong call is a setup error" equals "${STATUS}" "2"

if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
  mkdir -p "${BASE}/tree/commands"
  printf '[plugin]\nversion="1.2.0"\n' > "${BASE}/tree/plugin.cfg"
  printf 'extends RefCounted\n' > "${BASE}/tree/commands/a.gd"
  printf 'uid://a\n' > "${BASE}/tree/commands/a.gd.uid"
  printf '' > "${BASE}/tree/.hidden"
  rf_write_list "${BASE}/tree"
  zip_case "${BASE}" "${CASE_ZIP}"
  write_true_manifest "${BASE}" "${CASE_ZIP}" 1.2.0
  BASE_SIZE="$(file_size "${BASE}/${CASE_ZIP}")"
  BASE_HASH="$(openssl_sha256 "${BASE}/${CASE_ZIP}")"

  new_case clean
  run_case clean
  check "a clean release passes" equals "${STATUS}" "0"

  new_case booted
  printf 'engine state\n' > "${CASES}/booted/tree/icon.svg.import"
  run_case booted
  check "the engine's *.import is allowed" equals "${STATUS}" "0"

  new_case import-suffix
  printf 'a backup\n' > "${CASES}/import-suffix/tree/icon.svg.import.bak"
  run_case import-suffix
  check "a name that only holds .import fails" equals "${STATUS}" "1"
  check "its report names the file" contains "${OUT}" "icon.svg.import.bak"

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

  # sha256sum -c ignores a line with no hash, and the line still counts as listing the file.
  new_case listed-bare
  printf 'written at runtime\n' > "${CASES}/listed-bare/tree/stray.cfg"
  printf 'stray.cfg\n' >> "${CASES}/listed-bare/tree/release_files.sha256"
  run_case listed-bare
  check "a stray file with a bare line added to the list fails" equals "${STATUS}" "1"
  check "its report says the list is not the zip's" contains "${OUT}" "is not the zip's"

  new_case listed-hash
  printf 'written at runtime\n' > "${CASES}/listed-hash/tree/stray.cfg"
  printf '%s  stray.cfg\n' "$(openssl_sha256 "${CASES}/listed-hash/tree/stray.cfg")" >> "${CASES}/listed-hash/tree/release_files.sha256"
  run_case listed-hash
  check "a stray file listed with a good hash fails" equals "${STATUS}" "1"
  check "its report says the list is not the zip's" contains "${OUT}" "is not the zip's"

  new_case zip-no-list
  rm "${CASES}/zip-no-list/tree/release_files.sha256"
  zip_case "${CASES}/zip-no-list" "${CASE_ZIP}"
  cp "${BASE}/tree/release_files.sha256" "${CASES}/zip-no-list/tree/release_files.sha256"
  write_true_manifest "${CASES}/zip-no-list" "${CASE_ZIP}" 1.2.0
  run_case zip-no-list
  check "a zip that holds no list fails" equals "${STATUS}" "1"
  check "its report says the list is not the zip's" contains "${OUT}" "is not the zip's"

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
  write_case_manifest "${CASES}/wrong-hash" "${BASE_SIZE}" "${HASH_HELLO}" 1.2.0 "${CASE_ZIP}"
  run_case wrong-hash
  check "a wrong hash fails" equals "${STATUS}" "1"
  check "its report names archive_sha256" contains "${OUT}" "archive_sha256 is '${HASH_HELLO}'"

  new_case wrong-size
  write_case_manifest "${CASES}/wrong-size" 4 "${BASE_HASH}" 1.2.0 "${CASE_ZIP}"
  run_case wrong-size
  check "a wrong size fails" equals "${STATUS}" "1"
  check "its report names archive_size" contains "${OUT}" "archive_size is '4'"

  new_case wrong-version
  write_case_manifest "${CASES}/wrong-version" "${BASE_SIZE}" "${BASE_HASH}" 1.2.1 "${CASE_ZIP}"
  run_case wrong-version
  check "a wrong version fails" equals "${STATUS}" "1"
  check "its report names the version" contains "${OUT}" "version is '1.2.1'"

  # The zip is rebuilt, so the plugin.cfg clause is the only thing left to fail.
  new_case tree-version
  printf '[plugin]\nversion="1.1.9"\n' > "${CASES}/tree-version/tree/plugin.cfg"
  rf_write_list "${CASES}/tree-version/tree"
  zip_case "${CASES}/tree-version" "${CASE_ZIP}"
  write_true_manifest "${CASES}/tree-version" "${CASE_ZIP}" 1.2.0
  run_case tree-version
  check "a plugin.cfg of another version fails" equals "${STATUS}" "1"
  check "its report names that version" contains "${OUT}" "plugin.cfg says '1.1.9'"

  new_case wrong-archive
  write_case_manifest "${CASES}/wrong-archive" "${BASE_SIZE}" "${BASE_HASH}" 1.2.0 other.zip
  run_case wrong-archive
  check "another archive name fails" equals "${STATUS}" "1"
  check "its report names the archive" contains "${OUT}" "archive is 'other.zip'"

  # A zip named for another version, in a manifest that names that zip and agrees with
  # the tree: only the zip name's clause is left to fail.
  new_case zip-name
  mv "${CASES}/zip-name/${CASE_ZIP}" "${CASES}/zip-name/godot-mcp-toolkit-1.2.1.zip"
  write_true_manifest "${CASES}/zip-name" godot-mcp-toolkit-1.2.1.zip 1.2.0
  run bash "${CHECK}" "${CASES}/zip-name/godot-mcp-toolkit-1.2.1.zip" "${CASES}/zip-name/manifest.json" "${CASES}/zip-name/tree"
  check "a zip named for another version fails" equals "${STATUS}" "1"
  check "its report names the zip" contains "${OUT}" "version is '1.2.0', the zip is godot-mcp-toolkit-1.2.1.zip"

  new_case tampered-zip
  printf 'x' >> "${CASES}/tampered-zip/${CASE_ZIP}"
  run_case tampered-zip
  check "a zip changed after the manifest fails" equals "${STATUS}" "1"
  check "a zip changed after the manifest fails on its hash" contains "${OUT}" "archive_sha256 is '${BASE_HASH}'"
else
  skip "the check's cases need zip and unzip"
fi

if [[ -f "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.zip" ]]; then
  mkdir -p "${WORK}/unzipped"
  unzip -q "${WORK}/bash-build/dist-plugin/godot-mcp-toolkit-1.2.0.zip" -d "${WORK}/unzipped" || true
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
