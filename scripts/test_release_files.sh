#!/usr/bin/env bash
# scripts/test_release_files.sh
# Tests the files a release publishes and the scripts around them, with no network, no
# Godot and no change to the repo. Fixtures and keys are generated at run time, so line
# endings in a checkout cannot move a pinned hash, and no key lives in the repo:
#   - scripts/lib/release_files.sh against known SHA-256 vectors and a fixed manifest;
#   - both build scripts on a fixture repo: the missing .uid and the unreadable commit
#     time refused, the list and manifest pinned, the .ps1 matching them and ASCII; the
#     bash build also refusing an unreadable Godot floor or server pin;
#   - scripts/sign-release.sh as a copy inside a tagged repo made here, with a bare repo
#     as its origin, its own release identity and stand-ins for node, gh and ls: plain,
#     encrypted, unlisted and non-RSA keys, each check signing refuses on, what it shows
#     before it asks for the commit's digits, the folder a signature is left in, and
#     --verify against the trust documents at the tag;
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
# The script under test is a copy inside the fixture repo: it reads the repository it sits
# in, and no variable may aim it at another.
SIGN_REPO="${WORK}/sign-repo"
SIGN="${SIGN_REPO}/scripts/sign-release.sh"
TRUST_TOOL="${REPO_ROOT}/scripts/trust-document.sh"
KEYS="${WORK}/keys"
DOCUMENTS="${KEYS}/documents"
SIGNING="${WORK}/signing"
# Stands in for /Users/Shared, the folder a signature is handed over through.
SHARED="${WORK}/shared"
SIGN_TMP="${WORK}/sign-tmp"
MANIFEST_NAME="godot-mcp-toolkit-1.2.0.update.json"
SIG_NAME="${MANIFEST_NAME}.sig"
EMBEDDED_FILE="addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd"
CONSTANT_FILE="addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd"
PASSPHRASE="fixture-passphrase"
UNUSED_LINE="a line a plain key does not need"
# What a run is handed on file descriptor 3 when it refuses before it reads the commit's
# digits there.
NEVER_READ="never read"
mkdir -p "${KEYS}" "${DOCUMENTS}/pinned" "${DOCUMENTS}/other" "${SIGNING}" "${SHARED}" "${SIGN_TMP}"

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

# The fixture's trust documents: the first, signed by the root and listing the plain and
# the encrypted key; a second that drops the plain key, kept both unsigned and signed;
# and another first document, signed and valid, that the fixture's identity does not pin.
# trust-document.sh's sign reads a passphrase line from a pipe even for a plain key.
sign_document() {
  echo unused | bash "${TRUST_TOOL}" sign "$1" "$2" >/dev/null
}
FIRST="${DOCUMENTS}/pinned/trust-1.json"
SECOND="${DOCUMENTS}/pinned/trust-2.json"
UNSIGNED_SECOND="${DOCUMENTS}/unsigned-2.json"
OTHER_FIRST="${DOCUMENTS}/other/trust-1.json"
bash "${TRUST_TOOL}" build --first --add-root "${KEYS}/root.pub.pem" \
  --add-release "${KEYS}/plain.pub.pem" --add-release "${KEYS}/encrypted.pub.pem" --out "${DOCUMENTS}/pinned" >/dev/null
sign_document "${FIRST}" "${KEYS}/root.pem"
bash "${TRUST_TOOL}" build "${FIRST}" --drop-release "${KEYS}/plain.pub.pem" >/dev/null
cp "${SECOND}" "${UNSIGNED_SECOND}"
sign_document "${SECOND}" "${KEYS}/root.pem"
bash "${TRUST_TOOL}" build --first --add-root "${KEYS}/unlisted.pub.pem" \
  --add-release "${KEYS}/plain.pub.pem" --out "${DOCUMENTS}/other" >/dev/null
sign_document "${OTHER_FIRST}" "${KEYS}/unlisted.pem"

# git in the fixture repo. Every commit carries one fixed time, which a manifest's expiry
# counts from.
sign_git() {
  GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" \
    git -C "${SIGN_REPO}" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# Sets the fixture's trust folder to the files given as <name>=<source>, and the document
# its toolkit embeds to the file $1.
set_trust() {
  local embedded="$1" pair
  shift
  rm -rf "${SIGN_REPO}/trust"
  mkdir -p "${SIGN_REPO}/trust"
  for pair in "$@"; do
    cp "${pair#*=}" "${SIGN_REPO}/trust/${pair%%=*}"
  done
  printf "@tool\nextends RefCounted\n\nconst DOCUMENT := '%s'\n" "$(cat "${embedded}")" > "${SIGN_REPO}/${EMBEDDED_FILE}"
}

# Commits the fixture's tree as it stands and tags that commit $1 with an annotated tag,
# the kind a release gets.
tag_state() {
  sign_git add -A .
  sign_git commit -q --allow-empty -m "$1"
  sign_git tag -a -m "$1" "$1"
}

commit_of() {
  git -C "${SIGN_REPO}" rev-parse "refs/tags/$1^{commit}"
}

# The fixture: a bare repo as origin, and a clone-like repo that holds the scripts under
# test and a release identity naming that origin and the first document above. No
# variable overrides the identity, so the fixture writes its own.
git init -q --bare "${WORK}/origin.git"
mkdir -p "${SIGN_REPO}/scripts/lib" "$(dirname "${SIGN_REPO}/${EMBEDDED_FILE}")" "$(dirname "${SIGN_REPO}/${CONSTANT_FILE}")"
git -C "${SIGN_REPO}" init -q
git -C "${SIGN_REPO}" symbolic-ref HEAD refs/heads/main
git -C "${SIGN_REPO}" config core.autocrlf false
git -C "${SIGN_REPO}" remote add origin "${WORK}/origin.git"
cp "${REPO_ROOT}/scripts/sign-release.sh" "${REPO_ROOT}/scripts/trust-document.sh" "${SIGN_REPO}/scripts/"
cp "${REPO_ROOT}/scripts/lib/release_checks.sh" "${REPO_ROOT}/scripts/lib/release_files.sh" \
  "${REPO_ROOT}/scripts/lib/compatible_server.sh" "${SIGN_REPO}/scripts/lib/"
# git on Windows rewrites the path it is given, so the identity pins the URL as git
# reports it.
ORIGIN_URL="$(git -C "${SIGN_REPO}" remote get-url origin)"
cat > "${SIGN_REPO}/scripts/lib/release_identity.sh" <<IDENTITY
RELEASE_SLUG='fixture/sign-repo'
RELEASE_ORIGIN_URL='${ORIGIN_URL}'
RELEASE_BRANCH='main'
RELEASE_TRUST_1_SHA256='$(rf_sha256 "${FIRST}")'
IDENTITY
printf 'const GODOT_MIN_VERSION := "4.2"\nconst COMPATIBLE_SERVER_VERSION := "1.3.0"\n' > "${SIGN_REPO}/${CONSTANT_FILE}"

# One commit on main and one tag per state. v1.1.0 holds no trust document and is a
# lightweight tag, which origin lists with no ^{} line.
sign_git add -A .
sign_git commit -q -m v1.1.0
sign_git tag v1.1.0
set_trust "${FIRST}" "trust-1.json=${FIRST}"
tag_state v1.2.0
# trust-2 drops the plain key.
set_trust "${SECOND}" "trust-1.json=${FIRST}" "trust-2.json=${SECOND}"
tag_state v1.2.1
# Another first document than the pinned one.
set_trust "${OTHER_FIRST}" "trust-1.json=${OTHER_FIRST}"
tag_state v1.3.0
# A second document no root signed.
set_trust "${UNSIGNED_SECOND}" "trust-1.json=${FIRST}" "trust-2.json=${UNSIGNED_SECOND}"
tag_state v1.3.1
# A gap where trust-2.json belongs.
set_trust "${SECOND}" "trust-1.json=${FIRST}" "trust-3.json=${SECOND}"
tag_state v1.3.2
# A file named like a trust document that is none.
set_trust "${SECOND}" "trust-1.json=${FIRST}" "trust-2.json=${SECOND}" "trust-01.json=${FIRST}"
tag_state v1.3.3
# The toolkit embeds the first document while the tag's highest is the second.
set_trust "${FIRST}" "trust-1.json=${FIRST}" "trust-2.json=${SECOND}"
tag_state v1.3.4
# No Godot floor for the manifest.
set_trust "${SECOND}" "trust-1.json=${FIRST}" "trust-2.json=${SECOND}"
printf 'const COMPATIBLE_SERVER_VERSION := "1.3.0"\n' > "${SIGN_REPO}/${CONSTANT_FILE}"
tag_state v1.3.5
# A release tag on a commit that never reached main.
sign_git checkout -q -b side "$(commit_of v1.2.0)"
tag_state v1.4.0
sign_git checkout -q main
# A later version's tag on the commit of v1.2.1, which is not the release before v1.2.1.
sign_git tag -a -m v1.10.0 v1.10.0 "$(commit_of v1.2.1)"
# v1.6.0 and v1.7.0 go to origin on main's tip, v1.3.5's commit, which no tag signed
# below reaches. Then this checkout moves the first and drops the second, and makes
# v1.5.0, which origin never gets.
sign_git tag -a -m v1.6.0 v1.6.0 "$(commit_of v1.3.5)"
sign_git tag -a -m v1.7.0 v1.7.0 "$(commit_of v1.3.5)"
sign_git push -q origin main --tags
sign_git tag -f -a -m v1.6.0 v1.6.0 "$(commit_of v1.3.4)" >/dev/null
sign_git tag -d v1.7.0 >/dev/null
sign_git tag -a -m v1.5.0 v1.5.0 "$(commit_of v1.3.5)"

# Stand-ins on the PATH for the tools signing could reach: a node that logs where and how
# it was run, prints what the file ${NODE_SAYS} holds when there is one, on stdout and
# again on stderr behind "on stderr: ", and accepts the zip unless the file
# ${NODE_REFUSES} exists; a gh that only logs, because signing must never run it; and an
# ls that answers for a folder's owner and mode with what the file ${LS_SAYS} holds when
# there is one, since no test can make a folder another account owns.
export NODE_LOG="${WORK}/node.log"
export NODE_SAYS="${WORK}/node-says"
export NODE_REFUSES="${WORK}/node-refuses"
export GH_LOG="${WORK}/gh.log"
export LS_SAYS="${WORK}/ls-says"
REAL_LS="$(command -v ls)"
export REAL_LS
mkdir -p "${WORK}/stub"
cat > "${WORK}/stub/node" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd)" "$*" >> "${NODE_LOG}"
if [[ -f "${NODE_SAYS}" ]]; then
  cat "${NODE_SAYS}"
  sed 's/^/on stderr: /' "${NODE_SAYS}" >&2
fi
[[ ! -e "${NODE_REFUSES}" ]]
STUB
cat > "${WORK}/stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
STUB
cat > "${WORK}/stub/ls" <<'STUB'
#!/usr/bin/env bash
if [[ -f "${LS_SAYS}" && "${1:-}" == "-ldn" ]]; then
  cat "${LS_SAYS}"
else
  exec "${REAL_LS}" "$@"
fi
STUB
chmod +x "${WORK}/stub/node" "${WORK}/stub/gh" "${WORK}/stub/ls"

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

PATH="${WORK}/stub:${ORIGINAL_PATH}"

# The zip signing is handed, under a name that is not the release's, and beside it a
# manifest that signing must not read: it claims another size than the zip has.
ZIP="${SIGNING}/handed-over.zip"
printf 'abc' > "${ZIP}"
printf '{"format": 1, "version": "1.2.0", "archive": "godot-mcp-toolkit-1.2.0.zip", "archive_size": 3, "archive_sha256": "%s", "min_godot": "4.2", "compatible_server": "1.3.0", "expires_at": 1715552000}\n' "${HASH_ABC}" > "${WORK}/signed.expected"
sed 's/"archive_size": 3/"archive_size": 4/' "${WORK}/signed.expected" > "${SIGNING}/${MANIFEST_NAME}"

# The first 8 hex digits of the commit of the tag $1: what the maintainer types.
typed_for() {
  local commit
  commit="$(commit_of "$1")"
  printf '%s\n' "${commit:0:8}"
}

# Runs the fixture's sign-release.sh as from a pipe. The line $1 goes to its stdin, where
# it reads the passphrase, and the line $2 to its file descriptor 3, where it reads the
# commit's digits when stdin is no terminal. The variables in SIGN_ENV are set for that
# run only. SIGN_KEY keeps the key the run was given, its last argument.
SIGN_ENV=()
sign_piped() {
  local stdin_line="$1" typed="$2"
  shift 2
  SIGN_KEY="${*: -1}"
  rm -f "${OPENSSL_LOG}"
  OUT="$(env TMPDIR="${SIGN_TMP}" SIGN_RELEASE_OUT_ROOT="${SHARED}" ${SIGN_ENV[@]+"${SIGN_ENV[@]}"} \
    bash "${SIGN}" "$@" 2>&1 3< <(printf '%s\n' "${typed}") < <(printf '%s\n' "${stdin_line}"))" && STATUS=0 || STATUS=$?
}
sign_verify() {
  run env TMPDIR="${SIGN_TMP}" bash "${SIGN}" --verify "$@"
}

# The folder the last run left its signature in, from its last line.
out_folder() {
  printf '%s\n' "${OUT}" | tail -n 1 | sed 's/^OUT //'
}
# How many folders signing has left for the other account; SHARED_KEPT counts the ones
# the good runs so far should have.
shared_folders() {
  find "${SHARED}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}
SHARED_KEPT=0
mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Checks that the last run refused before it reached the private key: exit 1, the reason
# $2, no folder left, and no read of the key.
sign_refused() {
  check "$1: refused" equals "${STATUS}" "1"
  check "$1: says why" contains "${OUT}" "refused: "
  check "$1: names the reason" contains "${OUT}" "$2"
  check "$1: leaves no folder" equals "$(shared_folders)" "${SHARED_KEPT}"
  check "$1: the private key is not read" equals "$(private_key_reads "${SIGN_KEY}")" "0"
}

# A closed umask, so the folder and its files are readable from another account only
# because signing opens them.
OUTER_UMASK="$(umask)"
umask 077
sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
umask "${OUTER_UMASK}"
PLAIN_OUT="$(out_folder)"
SHARED_KEPT=1
check "plain key through the pipe: signed" equals "${STATUS}" "0"
check "plain key: the last line names a new folder under the hand-over folder" contains "${PLAIN_OUT}" "${SHARED}/sign-release-v1.2.0."
check "plain key: it is the only folder left there" equals "$(shared_folders)" "1"
check "plain key: the line before the last names the attach step, with the tag and that folder" contains "$(printf '%s\n' "${OUT}" | tail -n 2 | head -n 1)" "scripts/publish-release.sh attach v1.2.0 ${PLAIN_OUT}"
check "plain key: the folder holds the manifest and its .sig, nothing else" equals "$(find "${PLAIN_OUT}" -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')" "${PLAIN_OUT}/${MANIFEST_NAME} ${PLAIN_OUT}/${SIG_NAME} "
check "plain key: the manifest is the one the tag and the zip give, named for the version, not the one beside the zip" same_bytes "${PLAIN_OUT}/${MANIFEST_NAME}" "${WORK}/signed.expected"
check "plain key: the .sig verifies with openssl directly" verifies "${KEYS}/plain.pub.pem" "${PLAIN_OUT}/${SIG_NAME}" "${PLAIN_OUT}/${MANIFEST_NAME}"
check "plain key: the raw 256-byte signature of an RSA-2048 key" equals "$(file_size "${PLAIN_OUT}/${SIG_NAME}")" "256"
check "plain key: the folder is open to another account" equals "$(mode_of "${PLAIN_OUT}")" "755"
check "plain key: the manifest is readable from another account" equals "$(mode_of "${PLAIN_OUT}/${MANIFEST_NAME}")" "644"
check "plain key: the .sig is readable from another account" equals "$(mode_of "${PLAIN_OUT}/${SIG_NAME}")" "644"
check "plain key: the zip check runs in the repository, on the script's own copy of the zip and the tag" contains "$(cat "${NODE_LOG}")" "${SIGN_REPO}|${SIGN_REPO}/scripts/check-release-zip.mjs ${SIGN_TMP}/sign-release."
check "plain key: that copy carries the release's name" contains "$(cat "${NODE_LOG}")" "/godot-mcp-toolkit-1.2.0.zip v1.2.0"
check "plain key: the zip check is not handed the zip's own path" lacks "$(cat "${NODE_LOG}")" "handed-over.zip"
check "plain key: the tag is shown" contains "${OUT}" "Tag      v1.2.0"
check "plain key: its commit is shown in full" contains "${OUT}" "Commit   $(commit_of v1.2.0)"
check "plain key: the commit's subject is shown" contains "${OUT}" "Subject  v1.2.0"
check "plain key: the commits since the release before are counted" contains "${OUT}" "Commits since v1.1.0 (1):"
check "plain key: what changed under trust/ since then is shown" contains "${OUT}" "trust/trust-1.json"
check "plain key: the release before is shown with its commit and that commit's date" contains "${OUT}" "Before   v1.1.0 $(commit_of v1.1.0) 2023-11-14T22:13:20+00:00"
sign_verify "${PLAIN_OUT}/${MANIFEST_NAME}"
check "--verify accepts the signed manifest" equals "${STATUS}" "0"

sign_piped "${PASSPHRASE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/encrypted.pem"
ENCRYPTED_OUT="$(out_folder)"
SHARED_KEPT=2
check "encrypted key through a pipe: signed" equals "${STATUS}" "0"
check "encrypted key: the .sig verifies with openssl directly" verifies "${KEYS}/encrypted.pub.pem" "${ENCRYPTED_OUT}/${SIG_NAME}" "${ENCRYPTED_OUT}/${MANIFEST_NAME}"
check "the private key is read exactly once" equals "$(private_key_reads "${KEYS}/encrypted.pem")" "1"
check "a second signature gets a folder of its own" equals "$(shared_folders)" "2"

sign_piped "not-the-passphrase" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/encrypted.pem"
check "the wrong passphrase fails" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"
check "the wrong passphrase leaves no folder" equals "$(shared_folders)" "${SHARED_KEPT}"

sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/ec.pem"
check "an EC key is refused" equals "${STATUS}" "1"
check "the refusal says RSA" contains "${OUT}" "not an RSA key"
check "the refusal comes at the one read of the private key" equals "$(private_key_reads "${KEYS}/ec.pem")" "1"
check "the refusal leaves no folder" equals "$(shared_folders)" "${SHARED_KEPT}"

# An RSA-PSS key prints a modulus like a plain RSA key, but signs with another padding.
# An openssl may not make such a key, or may not print one.
if openssl genpkey -algorithm RSA-PSS -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/pss.pem" 2>/dev/null \
  && openssl pkey -in "${KEYS}/pss.pem" -pubout -out "${KEYS}/pss.pub.pem" 2>/dev/null \
  && openssl pkey -pubin -in "${KEYS}/pss.pub.pem" -noout -text >/dev/null 2>&1; then
  sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/pss.pem"
  check "an RSA-PSS key is refused" equals "${STATUS}" "1"
  check "the RSA-PSS refusal says RSA" contains "${OUT}" "not an RSA key"
  check "the RSA-PSS refusal leaves no folder" equals "$(shared_folders)" "${SHARED_KEPT}"
else
  skip "the RSA-PSS case needs an openssl that makes and prints such a key"
fi

echo "── sign-release.sh: each check refuses ──"
for name in GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE NODE_OPTIONS; do
  # Set to nothing still counts; GIT_DIR names the fixture's own repository, the one value
  # that would otherwise change nothing.
  SIGN_ENV=("${name}=")
  [[ "${name}" != "GIT_DIR" ]] || SIGN_ENV=("GIT_DIR=${SIGN_REPO}/.git")
  sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
  sign_refused "check 1, ${name} is set" "${name} is set"
done
# The other variables check 1 refuses: two with every check of a refusal, then one run
# each for the rest.
for name in GIT_CONFIG_GLOBAL OPENSSL_CONF; do
  SIGN_ENV=("${name}=")
  sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
  sign_refused "check 1, ${name} is set" "${name} is set"
done
NOT_REFUSED=""
for name in GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
  GIT_CONFIG_COUNT GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_SSL_NO_VERIFY GIT_SSH_COMMAND \
  GIT_PROXY_COMMAND GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE \
  NODE_PATH SSL_CERT_FILE SSL_CERT_DIR; do
  SIGN_ENV=("${name}=")
  sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
  [[ "${STATUS}" == "1" && "${OUT}" == *"refused: ${name} is set"* ]] || NOT_REFUSED+="${name} "
done
SIGN_ENV=()
check "check 1, each other variable that aims git elsewhere is refused" equals "${NOT_REFUSED}" ""

# A full copy of origin under another path: only the pinned URL tells them apart.
cp -R "${WORK}/origin.git" "${WORK}/elsewhere.git"
git -C "${SIGN_REPO}" remote set-url origin "${WORK}/elsewhere.git"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
git -C "${SIGN_REPO}" remote set-url origin "${ORIGIN_URL}"
sign_refused "check 2, origin is another repository" "not ${ORIGIN_URL}"

printf 'stray\n' > "${SIGN_REPO}/stray"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
rm "${SIGN_REPO}/stray"
sign_refused "check 3, an untracked file" "changed or untracked files"
printf '\n' >> "${SIGN_REPO}/scripts/trust-document.sh"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_git checkout -q -- scripts/trust-document.sh
sign_refused "check 3, a changed script" "changed or untracked files"
sign_git commit -q --allow-empty -m "never pushed"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_git reset -q --hard "HEAD~1"
sign_refused "check 3, a commit origin does not have" "not the tip of origin's main"

sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.6.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 4, a tag this checkout moved" "the tag v1.6.0 is $(commit_of v1.3.4) in this checkout and $(commit_of v1.3.5) on origin"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.5.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 4, a tag origin does not have" "origin has no tag v1.5.0"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.7.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 4, a tag this checkout does not have" "this checkout has no tag v1.7.0"

sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.4.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 5, a tag whose commit is not on main" "is not on origin's main"

# v1.1.0 is the lightweight tag: reaching this refusal shows check 4 took its one line.
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.1.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 6, a tag with no trust document" "holds no trust document"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 6, another first document than the pinned one" "the first trust document is pinned to $(rf_sha256 "${FIRST}")"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.1 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 6, a document no root signed" "trust-2.json at v1.3.1 does not verify against trust-1.json"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.2 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 6, a gap in the documents" "with no gap"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.3 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 6, a file named like a document" "trust/trust-01.json, which is named like a trust document"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.4 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 6, the toolkit embeds another document" "does not embed trust-2.json"

: > "${NODE_REFUSES}"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
rm "${NODE_REFUSES}"
sign_refused "check 7, a zip the zip check does not accept" "does not accept godot-mcp-toolkit-1.2.0.zip for v1.2.0"

sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.3.5 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 8, a tag the manifest cannot be written from" "could not read the manifest's fields from v1.3.5"

sign_piped "${UNUSED_LINE}" "0000000g" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 9, other digits than the commit's" "not the first 8 hex digits of the commit of v1.2.0"
check "check 9, other digits than the commit's: what was typed is not shown" lacks "${OUT}" "0000000g"
EIGHT_DIGITS="$(typed_for v1.2.0)"
check "check 9, other digits than the commit's: the commit's own digits are not shown" lacks "${OUT}" "${EIGHT_DIGITS}"
check "check 9: the page to read the commit on is named" contains "${OUT}" "open https://github.com/fixture/sign-repo/releases/tag/v1.2.0 and follow its commit link"
sign_piped "${UNUSED_LINE}" "${EIGHT_DIGITS:0:7}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 9, seven of the eight digits" "not the first 8 hex digits of the commit of v1.2.0"
sign_piped "${UNUSED_LINE}" "" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "check 9, nothing typed" "not the first 8 hex digits of the commit of v1.2.0"

sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/unlisted.pem"
check "check 10, a key that is no release key of the document at the tag fails" equals "${STATUS}" "1"
check "check 10: the failure leaves no folder" equals "$(shared_folders)" "${SHARED_KEPT}"
check "check 10: the failure leaves no scratch" equals "$(find "${SIGN_TMP}" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "check 10: the failure names the document and its tag" contains "${OUT}" "none of the 2 release keys of trust-1.json at v1.2.0"

echo "── sign-release.sh: the trust document at the tag ──"
# v1.2.1's highest document is trust-2, which dropped the plain key.
sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.1)" v1.2.1 "${ZIP}" "${KEYS}/plain.pem"
check "a key the tag's newest document dropped is refused" equals "${STATUS}" "1"
check "that refusal names the newest document" contains "${OUT}" "none of the 1 release keys of trust-2.json at v1.2.1"
sign_piped "${PASSPHRASE}" "$(typed_for v1.2.1)" v1.2.1 "${ZIP}" "${KEYS}/encrypted.pem"
NEWER_OUT="$(out_folder)"
SHARED_KEPT=3
check "the key that document keeps signs" equals "${STATUS}" "0"
check "the release before is the highest lower version the commit reaches, not v1.10.0 on the same commit" contains "${OUT}" "Commits since v1.2.0 (1):"
check "its folder is named for its tag" contains "${NEWER_OUT}" "${SHARED}/sign-release-v1.2.1."
check "and holds that version's .sig" is_file "${NEWER_OUT}/godot-mcp-toolkit-1.2.1.update.json.sig"
sign_verify "${NEWER_OUT}/godot-mcp-toolkit-1.2.1.update.json"
check "--verify accepts it against trust-2" contains "${OUT}" "verifies under a release key of trust-2.json at v1.2.1"
sign_verify "${PLAIN_OUT}/${MANIFEST_NAME}"
check "an older release still verifies against the document at its own tag" equals "${STATUS}" "0"
sign_verify "${ENCRYPTED_OUT}/${MANIFEST_NAME}"
check "--verify accepts a .sig by the document's second release key" equals "${STATUS}" "0"

# Gives a new folder, $1, the signed manifest with its version changed to $2, under that
# version's name.
make_versioned_case() {
  mkdir -p "${SIGNING}/$1"
  sed "s/\"version\": \"1.2.0\"/\"version\": \"$2\"/" "${WORK}/signed.expected" > "${SIGNING}/$1/godot-mcp-toolkit-$2.update.json"
}
# Signs the manifest $1 with the key $2 and openssl alone, so --verify alone judges it.
sign_directly() {
  openssl dgst -sha256 -sign "$2" -passin "pass:${PASSPHRASE}" -out "$1.sig" "$1" </dev/null
}

mkdir -p "${SIGNING}/changed" "${SIGNING}/renamed" "${SIGNING}/path-named" "${SIGNING}/no-version"
sed 's/"archive_size": 3/"archive_size": 4/' "${PLAIN_OUT}/${MANIFEST_NAME}" > "${SIGNING}/changed/${MANIFEST_NAME}"
cp "${PLAIN_OUT}/${SIG_NAME}" "${SIGNING}/changed/${SIG_NAME}"
sign_verify "${SIGNING}/changed/${MANIFEST_NAME}"
check "--verify rejects a one-byte change" equals "$([[ "${STATUS}" -ne 0 ]] && echo failed || echo passed)" "failed"

cp "${PLAIN_OUT}/${MANIFEST_NAME}" "${SIGNING}/renamed/some-other-name.json"
cp "${PLAIN_OUT}/${SIG_NAME}" "${SIGNING}/renamed/${SIG_NAME}"
sign_verify "${SIGNING}/renamed/some-other-name.json"
check "--verify finds the .sig by the manifest's version, whatever the manifest's own name" equals "${STATUS}" "0"
cp "${PLAIN_OUT}/${MANIFEST_NAME}" "${SIGNING}/path-named/some-other-name.json"
cp "${PLAIN_OUT}/${SIG_NAME}" "${SIGNING}/path-named/some-other-name.json.sig"
sign_verify "${SIGNING}/path-named/some-other-name.json"
check "--verify does not take a .sig named after the manifest's path" contains "${OUT}" "no signature at ${SIGNING}/path-named/${SIG_NAME}"

printf '{"format": 1, "version": "../../evil"}\n' > "${SIGNING}/no-version/${MANIFEST_NAME}"
sign_verify "${SIGNING}/no-version/${MANIFEST_NAME}"
check "a version that is no version is refused" equals "${STATUS}" "1"
check "the refusal says the version is the problem" contains "${OUT}" "no usable version"

make_versioned_case no-sig 1.2.0
sign_verify "${SIGNING}/no-sig/${MANIFEST_NAME}"
check "--verify with no .sig is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no signature at"

make_versioned_case unlisted 1.2.0
sign_directly "${SIGNING}/unlisted/${MANIFEST_NAME}" "${KEYS}/unlisted.pem"
sign_verify "${SIGNING}/unlisted/${MANIFEST_NAME}"
check "--verify refuses a .sig by a key the document does not list" equals "${STATUS}" "1"
check "that refusal names the document" contains "${OUT}" "none of the 2 release keys of trust-1.json at v1.2.0"

make_versioned_case no-document 1.1.0
sign_directly "${SIGNING}/no-document/godot-mcp-toolkit-1.1.0.update.json" "${KEYS}/plain.pem"
sign_verify "${SIGNING}/no-document/godot-mcp-toolkit-1.1.0.update.json"
check "a tag with no trust document is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "holds no trust document"
make_versioned_case no-tag 9.9.9
sign_directly "${SIGNING}/no-tag/godot-mcp-toolkit-9.9.9.update.json" "${KEYS}/plain.pem"
sign_verify "${SIGNING}/no-tag/godot-mcp-toolkit-9.9.9.update.json"
check "a version with no tag is refused" equals "${STATUS}" "1"
check "that refusal names the tag" contains "${OUT}" "no tag v9.9.9"

# Each .sig below is by a key the tag's highest document lists, so only the check of the
# tag's documents stands between it and a pass.
make_versioned_case broken-chain 1.3.1
sign_directly "${SIGNING}/broken-chain/godot-mcp-toolkit-1.3.1.update.json" "${KEYS}/encrypted.pem"
sign_verify "${SIGNING}/broken-chain/godot-mcp-toolkit-1.3.1.update.json"
check "--verify refuses when a document at the tag is not signed by a root" equals "${STATUS}" "1"
check "that refusal names the broken link" contains "${OUT}" "trust-2.json at v1.3.1 does not verify against trust-1.json"
make_versioned_case other-first 1.3.0
sign_directly "${SIGNING}/other-first/godot-mcp-toolkit-1.3.0.update.json" "${KEYS}/plain.pem"
sign_verify "${SIGNING}/other-first/godot-mcp-toolkit-1.3.0.update.json"
check "--verify refuses when the tag's first document is not the pinned one" equals "${STATUS}" "1"
check "that refusal names the pin" contains "${OUT}" "the first trust document is pinned to"
make_versioned_case other-embedded 1.3.4
sign_directly "${SIGNING}/other-embedded/godot-mcp-toolkit-1.3.4.update.json" "${KEYS}/encrypted.pem"
sign_verify "${SIGNING}/other-embedded/godot-mcp-toolkit-1.3.4.update.json"
check "--verify refuses when the toolkit at the tag embeds another document" equals "${STATUS}" "1"
check "that refusal names the document the toolkit should embed" contains "${OUT}" "does not embed trust-2.json"
run env TMPDIR="${SIGN_TMP}" GIT_DIR="${SIGN_REPO}/.git" bash "${SIGN}" --verify "${PLAIN_OUT}/${MANIFEST_NAME}"
check "--verify refuses while GIT_DIR is set" equals "${STATUS}" "1"
check "that refusal names the variable" contains "${OUT}" "GIT_DIR is set"

echo "── sign-release.sh: what is shown, and where a signature is left ──"
# More states, made and pushed only here so that no run above meets them. v1.3.6 gives
# back the Godot floor v1.3.5 took, in a commit whose subject holds an escape sequence and
# a two-byte character; the subject goes in through a file, as bytes. v1.3.8 has the
# release tag before it, v1.3.7, on its own commit. v1.0.0 sits on the commit of v1.2.0,
# which no release tag of a lower version reaches.
printf 'const GODOT_MIN_VERSION := "4.2"\nconst COMPATIBLE_SERVER_VERSION := "1.3.0"\n' > "${SIGN_REPO}/${CONSTANT_FILE}"
printf 'a subject \033[2J with \303\251 in it\n' > "${WORK}/subject"
sign_git add -A .
sign_git commit -q -F "${WORK}/subject"
sign_git tag -a -m v1.3.6 v1.3.6
tag_state v1.3.8
sign_git tag -a -m v1.3.7 v1.3.7 "$(commit_of v1.3.8)"
sign_git tag -a -m v1.0.0 v1.0.0 "$(commit_of v1.2.0)"
sign_git push -q origin main refs/tags/v1.3.6 refs/tags/v1.3.7 refs/tags/v1.3.8 refs/tags/v1.0.0

sign_piped "${PASSPHRASE}" "$(typed_for v1.3.6)" v1.3.6 "${ZIP}" "${KEYS}/encrypted.pem"
SHARED_KEPT=4
check "a subject with an escape sequence: signed" equals "${STATUS}" "0"
check "the subject is shown with a question mark for each byte that is not printable ASCII" contains "${OUT}" "Subject  a subject ?[2J with ?? in it"
check "and so is its line in the list of commits, which carries no commit's name" contains "${OUT}" "Commits since v1.3.5 (1):"$'\n'"  a subject ?[2J with ?? in it"
check "no escape reaches the terminal from a subject" lacks "${OUT}" $'\033'

printf 'an entry \033[2J the zip names\n' > "${NODE_SAYS}"
sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
rm "${NODE_SAYS}"
SHARED_KEPT=5
check "a zip check that prints an escape sequence: signed" equals "${STATUS}" "0"
check "what the zip check prints is shown with a question mark for the escape" contains "${OUT}" "an entry ?[2J the zip names"
check "and so is what it prints on stderr" contains "${OUT}" "on stderr: an entry ?[2J the zip names"
check "no escape reaches the terminal from the zip check" lacks "${OUT}" $'\033'

# git ls-remote matches a pattern against the tail of a ref's name, so origin answers for
# main and for v1.2.0 with these two refs as well, which name another commit.
sign_git push -q origin "$(commit_of v1.1.0):refs/heads/a/refs/heads/main" "$(commit_of v1.1.0):refs/tags/a/refs/tags/v1.2.0"
check "origin answers for main with a second ref" equals "$(git -C "${SIGN_REPO}" ls-remote origin refs/heads/main | wc -l | tr -d ' ')" "2"
check "origin answers for v1.2.0 with a second ref" contains "$(git -C "${SIGN_REPO}" ls-remote origin refs/tags/v1.2.0)" "refs/tags/a/refs/tags/v1.2.0"
sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_git push -q origin ":refs/heads/a/refs/heads/main" ":refs/tags/a/refs/tags/v1.2.0"
SHARED_KEPT=6
check "refs whose names only end like the branch's and the tag's do not stand in for them" equals "${STATUS}" "0"

sign_piped "${PASSPHRASE}" "${NEVER_READ}" v1.3.8 "${ZIP}" "${KEYS}/encrypted.pem"
sign_refused "check 9, the release tag before on the tag's own commit" "v1.3.7, the release tag before v1.3.8, is on the commit of v1.3.8 itself"

sign_piped "${UNUSED_LINE}" "$(typed_for v1.0.0)" v1.0.0 "${ZIP}" "${KEYS}/plain.pem"
SHARED_KEPT=7
check "a tag no lower release tag reaches: signed" equals "${STATUS}" "0"
check "it is shown with no release before it" contains "${OUT}" "Before   no release tag"
check "every commit it reaches is counted" contains "${OUT}" "Commits with no release tag before it (2):"
check "and its trust document counts as a change" contains "${OUT}" "trust/trust-1.json"

# The folder a signature is left in, as the stand-in ls reports it: root's with no sticky
# bit, another account's, this account's with write for the group or for everyone and no
# sticky bit, then root's with the sticky bit, which /Users/Shared is.
OUT_ROOT_REFUSAL="is neither this account's own and closed to other accounts nor root's or this account's with the sticky bit set"
printf 'drwxrwxrwx 2 0 0 64 Jan  1 00:00 .\n' > "${LS_SAYS}"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "a hand-over folder of root's with no sticky bit" "${SHARED} ${OUT_ROOT_REFUSAL}"
printf 'drwxrwxrwt 2 %s 0 64 Jan  1 00:00 .\n' "$(($(id -u) + 1))" > "${LS_SAYS}"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "a hand-over folder of another account's" "${SHARED} ${OUT_ROOT_REFUSAL}"
printf 'drwxrwxr-x 2 %s 0 64 Jan  1 00:00 .\n' "$(id -u)" > "${LS_SAYS}"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "a hand-over folder of this account's its group may write to" "${SHARED} ${OUT_ROOT_REFUSAL}"
printf 'drwxr-xrwx 2 %s 0 64 Jan  1 00:00 .\n' "$(id -u)" > "${LS_SAYS}"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
sign_refused "a hand-over folder of this account's everyone may write to" "${SHARED} ${OUT_ROOT_REFUSAL}"
printf 'drwxrwxrwt 2 0 0 64 Jan  1 00:00 .\n' > "${LS_SAYS}"
sign_piped "${UNUSED_LINE}" "$(typed_for v1.2.0)" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
rm "${LS_SAYS}"
SHARED_KEPT=8
check "a hand-over folder of root's with the sticky bit takes the signature" equals "${STATUS}" "0"

echo "── sign-release.sh: usage ──"
run bash "${SIGN}" --help
check "the usage does not say where keys live" lacks "${OUT}" "embedded_trust_document"
check "the usage names the three-argument form" contains "${OUT}" "scripts/sign-release.sh <tag> <zip> <private-key.pem>"
check "the usage names no public key to pass" lacks "${OUT}" "<public-key.pem>"
SIGN_ENV=()
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem" "${KEYS}/plain.pub.pem"
check "a fourth argument is wrong usage" equals "${STATUS}" "2"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" "${PLAIN_OUT}/${MANIFEST_NAME}" "${KEYS}/plain.pem"
check "a manifest and a key, with no tag, is wrong usage" equals "${STATUS}" "2"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/no-such-key.pem"
check "a key file that is not there is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no key at"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${SIGNING}/no-such.zip" "${KEYS}/plain.pem"
check "a zip that is not there is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "no zip at"
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" 1.2.0 "${ZIP}" "${KEYS}/plain.pem"
check "a version where the tag belongs is refused" equals "${STATUS}" "1"
check "that refusal says so" contains "${OUT}" "is no release tag"
SIGN_ENV=("SIGN_RELEASE_OUT_ROOT=${WORK}/no-such-folder")
sign_piped "${UNUSED_LINE}" "${NEVER_READ}" v1.2.0 "${ZIP}" "${KEYS}/plain.pem"
SIGN_ENV=()
check "a hand-over folder that is not there is a setup error" equals "${STATUS}" "2"
check "and none is made" no_file "${WORK}/no-such-folder"
run bash "${SIGN}" --key-entry "${KEYS}/plain.pub.pem"
check "--key-entry is not a command" equals "${STATUS}" "2"
sign_verify "${SIGNING}/renamed/some-other-name.json" "${KEYS}/plain.pub.pem"
check "--verify takes no public key" equals "${STATUS}" "2"

check "no run started gh" no_file "${GH_LOG}"
check "the good runs left only their folders for the other account" equals "$(shared_folders)" "${SHARED_KEPT}"
check "no run left scratch behind" equals "$(find "${SIGN_TMP}" -mindepth 1 | wc -l | tr -d ' ')" "0"
PATH="${ORIGINAL_PATH}"

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
