#!/usr/bin/env bash
# scripts/test_publish_release.sh
# Tests scripts/publish-release.sh with no network, no GitHub, no Godot and no change to
# the repo. The script under test is a copy inside a tagged repository made here, with a
# bare repository as its origin and its own release identity, beside copies of the scripts
# it runs: sign-release.sh, trust-document.sh and scripts/lib. Keys and trust documents are
# generated at run time, so no key lives in the repo. First on the PATH are stand-ins:
#   - gh and curl, a GitHub made of files in the test's folder. Each exits 97 on a call
#     that does not name the fixture's repository, so a call left to gh's own guess fails
#     its row;
#   - node, which accepts a zip only when its SHA-256 is listed for the tag;
#   - two Godot binaries, named through GODOT_BIN_4_2 and GODOT_BIN_4_7, which log their
#     arguments and print the verdict a row sets. The script the reader check hands them
#     needs a real Godot and is not run here.
# The signatures come from the copied sign-release.sh, run with a key made here. Each step
# is done once for a tag with one trust document and once for a tag with two, and each
# refusal has a row that also checks nothing was written to GitHub. The rows about symlinks
# say "skip" where the file system makes none, as Git Bash on Windows does by default.
#
# Once the fixture is built, a fixture step that fails no longer stops the test: it is
# counted, and the last row fails unless the count is zero. Every row is then judged even
# when the script under test never reaches the state a later row starts from.
#
# Usage: bash scripts/test_publish_release.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed, 2 = a missing tool.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

for tool in git openssl zip unzip; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "error: ${tool} is required." >&2; exit 2; }
done

# Through cd and pwd for a path with no drive colon: it goes on the PATH below.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-publish-release.XXXXXX")" && pwd)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
# How many fixture steps between the rows failed. See the header.
FIXTURE_FAILURES=0
# The output of the last run of the script under test, the number of that run and the
# number of the last run whose output a failed row printed.
OUT=""
RUN=0
SHOWN_RUN=0

# A failed row prints what the run it judges said, once per run, so a failure can be read
# from the test's own output.
check() {
  local label="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "  ok    ${label}"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${label}"
    if [[ "${SHOWN_RUN}" -ne "${RUN}" ]]; then
      SHOWN_RUN="${RUN}"
      printf '%s\n' "${OUT}" | sed 's/^/        | /'
    fi
  fi
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  echo "  skip  $1"
}

equals() { [[ "$1" == "$2" ]]; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }
is_folder() { [[ -d "$1" ]]; }
is_file() { [[ -f "$1" ]]; }
no_file() { [[ ! -e "$1" ]]; }
same_bytes() { cmp -s "$1" "$2"; }
mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

REPO="${WORK}/repo"
PUBLISH="${REPO}/scripts/publish-release.sh"
SIGN="${REPO}/scripts/sign-release.sh"
TRUST_TOOL="${REPO_ROOT}/scripts/trust-document.sh"
KEYS="${WORK}/keys"
DOCUMENTS="${WORK}/documents"
BUILT="${WORK}/built"
HELD="${WORK}/held"
# Stands in for /Users/Shared, the folder the zip and the signature are handed over through.
SHARED="${WORK}/shared"
STUB="${WORK}/stub"
EMBEDDED_FILE="addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd"
CONSTANT_FILE="addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd"
# Every commit of the fixture carries one fixed time, and a manifest expires 180 days on.
COMMIT_TIME=1700000000
EXPIRES_AT=1715552000
export FAKE_GITHUB="${WORK}/github"
export FAKE_SLUG="fixture/publish-repo"
mkdir -p "${KEYS}" "${DOCUMENTS}/pinned" "${DOCUMENTS}/other" "${BUILT}" "${HELD}" "${SHARED}" "${STUB}" \
  "${WORK}/sign-tmp" "${FAKE_GITHUB}/releases" "${FAKE_GITHUB}/runs" "${FAKE_GITHUB}/branches"

echo "── the fixture ──"
# A root, the release key, a release key the second document retires, and a key no
# document lists as a release key.
for name in root release retired unlisted; do
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${KEYS}/${name}.pem" 2>/dev/null
  openssl pkey -in "${KEYS}/${name}.pem" -pubout -out "${KEYS}/${name}.pub.pem" 2>/dev/null
done

# trust-document.sh's sign reads a passphrase line from a pipe even for a plain key.
sign_document() {
  echo unused | bash "${TRUST_TOOL}" sign "$1" "$2" >/dev/null
}
FIRST="${DOCUMENTS}/pinned/trust-1.json"
SECOND="${DOCUMENTS}/pinned/trust-2.json"
OTHER_FIRST="${DOCUMENTS}/other/trust-1.json"
NOT_A_TAGS_DOCUMENT="${DOCUMENTS}/not-a-tags-document.json"
bash "${TRUST_TOOL}" build --first --add-root "${KEYS}/root.pub.pem" \
  --add-release "${KEYS}/release.pub.pem" --add-release "${KEYS}/retired.pub.pem" --out "${DOCUMENTS}/pinned" >/dev/null
sign_document "${FIRST}" "${KEYS}/root.pem"
bash "${TRUST_TOOL}" build "${FIRST}" --drop-release "${KEYS}/retired.pub.pem" >/dev/null
sign_document "${SECOND}" "${KEYS}/root.pem"
# A first document that is signed and valid, and that the fixture's identity does not pin.
bash "${TRUST_TOOL}" build --first --add-root "${KEYS}/unlisted.pub.pem" \
  --add-release "${KEYS}/release.pub.pem" --out "${DOCUMENTS}/other" >/dev/null
sign_document "${OTHER_FIRST}" "${KEYS}/unlisted.pem"
printf 'bytes no tag holds\n' > "${NOT_A_TAGS_DOCUMENT}"

repo_git() {
  GIT_AUTHOR_DATE="${COMMIT_TIME} +0000" GIT_COMMITTER_DATE="${COMMIT_TIME} +0000" \
    git -C "${REPO}" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# Sets the fixture's trust folder to the files given as <name>=<source>, and the document
# its toolkit embeds to the file $1.
set_trust() {
  local embedded="$1" pair
  shift
  rm -rf "${REPO}/trust"
  mkdir -p "${REPO}/trust"
  for pair in "$@"; do
    cp "${pair#*=}" "${REPO}/trust/${pair%%=*}"
  done
  printf "@tool\nextends RefCounted\n\nconst DOCUMENT := '%s'\n" "$(cat "${embedded}")" > "${REPO}/${EMBEDDED_FILE}"
}

# Commits the fixture's tree as it stands and tags that commit $1 with an annotated tag,
# the kind a release gets.
tag_state() {
  repo_git add -A .
  repo_git commit -q --allow-empty -m "$1"
  repo_git tag -a -m "$1" "$1"
}

commit_of() {
  git -C "${REPO}" rev-parse "refs/tags/$1^{commit}"
}

# The repository the scripts under test sit in: a bare repository as origin, and a release
# identity naming that origin and the first document above. No variable overrides the
# identity, so the fixture writes its own. check-release-zip.mjs only has to exist: the
# node on the PATH is a stand-in that never reads it.
git init -q --bare "${WORK}/origin.git"
mkdir -p "${REPO}/scripts/lib" "$(dirname "${REPO}/${EMBEDDED_FILE}")" "$(dirname "${REPO}/${CONSTANT_FILE}")"
git -C "${REPO}" init -q
git -C "${REPO}" symbolic-ref HEAD refs/heads/main
git -C "${REPO}" config core.autocrlf false
git -C "${REPO}" remote add origin "${WORK}/origin.git"
cp "${REPO_ROOT}/scripts/publish-release.sh" "${REPO_ROOT}/scripts/sign-release.sh" \
  "${REPO_ROOT}/scripts/trust-document.sh" "${REPO}/scripts/"
cp "${REPO_ROOT}/scripts/lib/release_checks.sh" "${REPO_ROOT}/scripts/lib/release_files.sh" \
  "${REPO_ROOT}/scripts/lib/compatible_server.sh" "${REPO_ROOT}/scripts/lib/update_test_env.sh" \
  "${REPO_ROOT}/scripts/lib/python_bin.sh" "${REPO}/scripts/lib/"
printf '// The fixture runs a stand-in node, which never reads this file.\n' > "${REPO}/scripts/check-release-zip.mjs"
printf 'dist-plugin/\n' > "${REPO}/.gitignore"
# git on Windows rewrites the path it is given, so the identity pins the URL as git
# reports it.
ORIGIN_URL="$(git -C "${REPO}" remote get-url origin)"
cat > "${REPO}/scripts/lib/release_identity.sh" <<IDENTITY
RELEASE_SLUG='${FAKE_SLUG}'
RELEASE_ORIGIN_URL='${ORIGIN_URL}'
RELEASE_BRANCH='main'
RELEASE_TRUST_1_SHA256='$(rf_sha256 "${FIRST}")'
IDENTITY
printf 'const GODOT_MIN_VERSION := "4.2"\nconst COMPATIBLE_SERVER_VERSION := "1.3.0"\n' > "${REPO}/${CONSTANT_FILE}"

# One commit on main and one tag per state. v1.1.2 is the release the fixture's GitHub
# starts with; it holds no trust document.
repo_git add -A .
repo_git commit -q -m v1.1.2
repo_git tag v1.1.2
set_trust "${FIRST}" "trust-1.json=${FIRST}"
tag_state v1.2.0
set_trust "${SECOND}" "trust-1.json=${FIRST}" "trust-2.json=${SECOND}"
tag_state v1.2.1
# Another first document than the pinned one.
set_trust "${OTHER_FIRST}" "trust-1.json=${OTHER_FIRST}"
tag_state v1.3.0
# A release tag on a commit that never reached main.
repo_git checkout -q -b side "$(commit_of v1.2.0)"
tag_state v1.4.0
repo_git checkout -q main
repo_git push -q origin main --tags

cat > "${STUB}/gh" <<'STUB'
#!/usr/bin/env bash
# A GitHub made of files under ${FAKE_GITHUB}: releases/<id>/{tag,draft,immutable,assets/}
# and, for a pre-release, releases/<id>/prerelease; runs/<id>/{commit,branch,
# artifacts/<name>/}, branches/<name>, latest (a release's id) and immutable-releases (the
# repository's setting; absent, the request fails). A row sets a hook by making a file:
#   assets-unread                  the request for a release's asset names fails;
#   asset-added-at-setting-read    holds a release's id, and that release gets one more
#                                  asset when the immutable-releases setting is read;
#   asset-added-at-publish         the release gets one more asset as it is published.
# gh api only ever reads here: a flag that would make it write exits 98.
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GITHUB}/gh.log"
named=0 jq="" commit="" branch="" name="" dir="" api_write=0
patterns=() flags=() positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X | --method | -f | -F | --field | --raw-field | --input) api_write=1; shift ;;
    --repo) if [[ "$2" == "${FAKE_SLUG}" ]]; then named=1; fi; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    --commit) commit="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --pattern) patterns+=("$2"); shift 2 ;;
    --workflow | --status | --limit | --json | --title | --notes) shift 2 ;;
    --*) flags+=("$1"); shift ;;
    *) positional+=("$1"); shift ;;
  esac
done
verb="${positional[0]:-} ${positional[1]:-}"
route=""
if [[ "${positional[0]:-}" == "api" ]]; then
  verb="api"
  route="${positional[1]:-}"
  if [[ "${route}" == "repos/${FAKE_SLUG}/"* ]]; then named=1; fi
  route="${route#"repos/${FAKE_SLUG}/"}"
  route="${route%%\?*}"
fi
if [[ "${named}" -ne 1 ]]; then
  echo "NOT-NAMED" >> "${FAKE_GITHUB}/gh.log"
  echo "gh stand-in: this call names no repository, or another one" >&2
  exit 97
fi

releases="${FAKE_GITHUB}/releases"
release_ids() {
  ls "${releases}" | sort -n
}
# Prints the id of the first release that carries the tag $1.
release_of() {
  local id
  for id in $(release_ids); do
    if [[ "$(cat "${releases}/${id}/tag")" == "$1" ]]; then
      echo "${id}"
      return 0
    fi
  done
  echo "gh stand-in: no release carries $1" >&2
  return 1
}

case "${verb}" in
  api)
    if [[ "${api_write}" -ne 0 ]]; then
      echo "gh stand-in: gh api is only ever asked to read" >&2
      exit 98
    fi
    case "${route}" in
      releases)
        for id in $(release_ids); do
          tag="$(cat "${releases}/${id}/tag")"
          draft="$(cat "${releases}/${id}/draft")"
          prerelease="false"
          [[ ! -e "${releases}/${id}/prerelease" ]] || prerelease="true"
          if [[ "${jq}" == *'.tag_name == "'* ]]; then
            wanted="${jq#*.tag_name == \"}"
            if [[ "${tag}" == "${wanted%%\"*}" ]]; then
              # Like jq, only a filter that asks whether it is a pre-release is told.
              if [[ "${jq}" == *'\(.prerelease)'* ]]; then
                echo "${id} ${draft} ${prerelease}"
              else
                echo "${id} ${draft}"
              fi
            fi
          elif [[ "${draft}" == "false" && "${prerelease}" == "false" ]]; then
            echo "${tag}"
          fi
        done
        ;;
      releases/latest)
        id="$(cat "${FAKE_GITHUB}/latest")"
        cat "${releases}/${id}/tag"
        ls "${releases}/${id}/assets"
        ;;
      releases/*/assets)
        [[ ! -e "${FAKE_GITHUB}/assets-unread" ]] || exit 1
        id="${route#releases/}"
        ls "${releases}/${id%/assets}/assets"
        ;;
      releases/*)
        cat "${releases}/${route#releases/}/immutable"
        ;;
      git/matching-refs/heads/*)
        if [[ -e "${FAKE_GITHUB}/branches/${route##*/}" ]]; then echo "refs/heads/${route##*/}"; fi
        ;;
      immutable-releases)
        if [[ -f "${FAKE_GITHUB}/asset-added-at-setting-read" ]]; then
          echo late > "${releases}/$(cat "${FAKE_GITHUB}/asset-added-at-setting-read")/assets/late.txt"
        fi
        cat "${FAKE_GITHUB}/immutable-releases"
        ;;
      *)
        echo "gh stand-in: no answer for ${route}" >&2
        exit 98
        ;;
    esac
    ;;
  "run list")
    for run in $(ls "${FAKE_GITHUB}/runs"); do
      if [[ "$(cat "${FAKE_GITHUB}/runs/${run}/commit")" == "${commit}" \
        && "$(cat "${FAKE_GITHUB}/runs/${run}/branch")" == "${branch}" ]]; then
        echo "${run}"
        break
      fi
    done
    ;;
  "run download")
    cp "${FAKE_GITHUB}/runs/${positional[2]}/artifacts/${name}"/* "${dir}/"
    ;;
  "release create")
    [[ ! -e "${FAKE_GITHUB}/create-fails" ]] || exit 1
    id="$(cat "${FAKE_GITHUB}/next-id")"
    echo "$((id + 1))" > "${FAKE_GITHUB}/next-id"
    mkdir -p "${releases}/${id}/assets"
    echo "${positional[2]}" > "${releases}/${id}/tag"
    echo true > "${releases}/${id}/draft"
    echo false > "${releases}/${id}/immutable"
    cp "${positional[@]:3}" "${releases}/${id}/assets/"
    ;;
  "release upload")
    id="$(release_of "${positional[2]}")"
    [[ ! -e "${releases}/${id}/assets/$(basename "${positional[3]}")" ]] || exit 1
    cp "${positional[3]}" "${releases}/${id}/assets/"
    ;;
  "release download")
    id="$(release_of "${positional[2]}")"
    matched=0
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      if [[ -f "${releases}/${id}/assets/${pattern}" ]]; then
        # Like gh, never over a file that is already there.
        [[ ! -e "${dir}/${pattern}" ]] || exit 1
        cp "${releases}/${id}/assets/${pattern}" "${dir}/"
        matched=1
      fi
    done
    [[ "${matched}" -eq 1 ]]
    ;;
  "release edit")
    id="$(release_of "${positional[2]}")"
    [[ " ${flags[*]-} " == *" --draft=false "* ]] || exit 98
    [[ ! -e "${FAKE_GITHUB}/asset-added-at-publish" ]] || echo late > "${releases}/${id}/assets/late.txt"
    echo false > "${releases}/${id}/draft"
    cat "${FAKE_GITHUB}/immutable-releases" > "${releases}/${id}/immutable"
    if [[ " ${flags[*]-} " == *" --latest "* ]]; then echo "${id}" > "${FAKE_GITHUB}/latest"; fi
    ;;
  "release verify")
    release_of "${positional[2]}" > /dev/null
    ;;
  "release verify-asset")
    id="$(release_of "${positional[2]}")"
    cmp -s "${positional[3]}" "${releases}/${id}/assets/$(basename "${positional[3]}")"
    ;;
  *)
    echo "gh stand-in: no answer for ${verb}" >&2
    exit 98
    ;;
esac
STUB

cat > "${STUB}/curl" <<'STUB'
#!/usr/bin/env bash
# What an anonymous reader is told the latest release of the fixture's GitHub is.
set -euo pipefail
for url in "$@"; do :; done
printf '%s\n' "${url}" >> "${FAKE_GITHUB}/curl.log"
if [[ "${url}" != "https://api.github.com/repos/${FAKE_SLUG}/releases/latest" ]]; then
  echo "NOT-NAMED" >> "${FAKE_GITHUB}/curl.log"
  exit 97
fi
printf '{"id": 1, "tag_name": "%s", "draft": false}\n' "$(cat "${FAKE_GITHUB}/releases/$(cat "${FAKE_GITHUB}/latest")/tag")"
STUB

cat > "${STUB}/node" <<'STUB'
#!/usr/bin/env bash
# Stands in for check-release-zip.mjs <zip> <tag>: a zip is the tag's when the file
# good-zips lists "<tag> <its SHA-256>".
set -euo pipefail
if command -v sha256sum >/dev/null 2>&1; then
  hash="$(sha256sum < "$2" | cut -d' ' -f1)"
else
  hash="$(shasum -a 256 < "$2" | cut -d' ' -f1)"
fi
if ! grep -qxF "$3 ${hash}" "${FAKE_GITHUB}/good-zips"; then
  echo "the zip is not the one built from $3"
  exit 1
fi
STUB

for minor in 4.2 4.7; do
  cat > "${STUB}/godot-${minor}" <<'STUB'
#!/usr/bin/env bash
# A Godot of the version in this file's name. It logs what it is asked to run and prints
# the reader check's verdict from the file godot-<version>.says, or "trusted".
minor="${0##*godot-}"
if [[ "${1:-}" == "--version" ]]; then
  echo "${minor}.stable.fixture"
  exit 0
fi
printf '%s\n' "$*" >> "${FAKE_GITHUB}/godot-${minor}.log"
verdict="trusted"
[[ ! -f "${FAKE_GITHUB}/godot-${minor}.says" ]] || verdict="$(cat "${FAKE_GITHUB}/godot-${minor}.says")"
echo "READER_CHECK_RESULT ${verdict}"
STUB
done
chmod +x "${STUB}/gh" "${STUB}/curl" "${STUB}/node" "${STUB}/godot-4.2" "${STUB}/godot-4.7"
PATH="${STUB}:${PATH}"

zip_name() { echo "godot-mcp-toolkit-${1#v}.zip"; }
manifest_name() { echo "godot-mcp-toolkit-${1#v}.update.json"; }
signature_name() { echo "godot-mcp-toolkit-${1#v}.update.json.sig"; }

# Builds the zip $1 names, holding a plugin.cfg of the version $2.
make_zip() {
  local zip="$1" tree="$1.tree"
  mkdir -p "${tree}/addons/godot_mcp_toolkit"
  printf '[plugin]\nversion="%s"\n' "$2" > "${tree}/addons/godot_mcp_toolkit/plugin.cfg"
  (cd "${tree}" && zip -q -r "${zip}" addons)
}

# What the release workflow builds for the tag $1: a zip the stand-in node accepts, and
# the manifest of that zip at the tag.
build_release() {
  local tag="$1" folder="${BUILT}/$1"
  mkdir -p "${folder}"
  make_zip "${folder}/$(zip_name "${tag}")" "${tag#v}"
  rf_write_manifest "${folder}/$(zip_name "${tag}")" "${tag#v}" "4.2" "1.3.0" "${EXPIRES_AT}" "${folder}/$(manifest_name "${tag}")"
  echo "${tag} $(rf_sha256 "${folder}/$(zip_name "${tag}")")" >> "${FAKE_GITHUB}/good-zips"
}

# Puts on the fixture's GitHub a release.yml run $1 that succeeded on the tag $2, with
# the artifact a build leaves.
seed_run() {
  local run="${FAKE_GITHUB}/runs/$1"
  mkdir -p "${run}/artifacts/release-$2"
  commit_of "$2" > "${run}/commit"
  echo "$2" > "${run}/branch"
  cp "${BUILT}/$2/$(zip_name "$2")" "${BUILT}/$2/$(manifest_name "$2")" "${run}/artifacts/release-$2/"
}

# Puts on the fixture's GitHub a published release with the id $1 and the tag $2.
seed_published() {
  mkdir -p "${FAKE_GITHUB}/releases/$1/assets"
  echo "$2" > "${FAKE_GITHUB}/releases/$1/tag"
  echo false > "${FAKE_GITHUB}/releases/$1/draft"
  echo true > "${FAKE_GITHUB}/releases/$1/immutable"
}

: > "${FAKE_GITHUB}/good-zips"
for tag in v1.2.0 v1.2.1 v1.3.0; do
  build_release "${tag}"
done
# A zip no tag built.
make_zip "${BUILT}/other.zip" "9.9.9"
seed_published 1 v1.1.2
echo 1 > "${FAKE_GITHUB}/latest"
echo true > "${FAKE_GITHUB}/immutable-releases"
echo 100 > "${FAKE_GITHUB}/next-id"

# Runs the fixture's publish-release.sh and keeps its combined output and exit status. The
# variables in RUN_ENV are set for that run only. The log of calls to GitHub starts empty,
# and a call that named no repository is counted across the whole test.
RUN_ENV=()
NOT_NAMED=0
publish_release() {
  RUN=$((RUN + 1))
  : > "${FAKE_GITHUB}/gh.log"
  : > "${FAKE_GITHUB}/curl.log"
  rm -f "${FAKE_GITHUB}/godot-4.2.log" "${FAKE_GITHUB}/godot-4.7.log"
  OUT="$(env PUBLISH_RELEASE_HANDOFF_ROOT="${SHARED}" SIGN_RELEASE_OUT_ROOT="${SHARED}" TMPDIR="${WORK}/sign-tmp" \
    GODOT_BIN_4_2="${STUB}/godot-4.2" GODOT_BIN_4_7="${STUB}/godot-4.7" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    bash "${PUBLISH}" "$@" 2>&1 < /dev/null)" && STATUS=0 || STATUS=$?
  NOT_NAMED=$((NOT_NAMED + $(cat "${FAKE_GITHUB}/gh.log" "${FAKE_GITHUB}/curl.log" | grep -c -x NOT-NAMED || true)))
}

# How many calls of the last run began with the words $1, such as "release edit".
gh_calls() {
  grep -c -E "^$1( |\$)" "${FAKE_GITHUB}/gh.log" || true
}
# How many calls of the last run created, changed, added to or deleted from a release. The
# stand-in refuses the other way to write, gh api with a method or a field.
gh_writes() {
  gh_calls "release (create|upload|edit|delete|delete-asset)"
}
# How many calls of the last run reached the stand-in gh at all.
gh_asked() {
  wc -l < "${FAKE_GITHUB}/gh.log" | tr -d ' '
}

# Checks that the last run refused for the reason $2 and wrote nothing to GitHub.
refused() {
  check "$1: refused" equals "${STATUS}" "1"
  check "$1: says why" contains "${OUT}" "$2"
  check "$1: writes nothing to GitHub" equals "$(gh_writes)" "0"
}

# Signs the zip $2 for the tag $1 with the copied sign-release.sh and the key $3, as the
# signing account does, and sets SIGNED_FOLDER to the folder it names as OUT. Its stdin
# line is the passphrase a plain key does not need, and file descriptor 3 carries the
# commit's first 8 hex digits.
sign_release() {
  local commit signed
  SIGNED_FOLDER=""
  commit="$(commit_of "$1")"
  signed="$(env TMPDIR="${WORK}/sign-tmp" SIGN_RELEASE_OUT_ROOT="${SHARED}" bash "${SIGN}" "$1" "$2" "$3" \
    2>&1 3< <(printf '%s\n' "${commit:0:8}") < <(printf 'unused\n'))" || { printf '%s\n' "${signed}"; return 1; }
  SIGNED_FOLDER="$(printf '%s\n' "${signed}" | tail -n 1 | sed 's/^OUT //')"
}

# Signs the file $2 with the key $1, as openssl signs a manifest, into the file $3.
sign_bytes() {
  openssl dgst -sha256 -sign "$1" -out "$3" "$2"
}

# The one folder under the hand-off root whose name starts with $1.
shared_folder() {
  find "${SHARED}" -mindepth 1 -maxdepth 1 -name "$1*"
}
shared_count() {
  find "${SHARED}" -mindepth 1 -maxdepth 1 -name "$1*" | wc -l | tr -d ' '
}

record_folder() { echo "${REPO}/dist-plugin/release-$1"; }
assets_of() { echo "${FAKE_GITHUB}/releases/$1/assets"; }
asset_list() { ls "$(assets_of "$1")" | LC_ALL=C sort | tr '\n' ' '; }

# Keeps, and puts back, the release $2 and the records of the tag $1 as they stand, so a
# row can change either and leave no trace. A release or records that are not there are
# kept as absent and put back as absent: a script under test that never drafted has none.
keep_state() {
  rm -rf "${HELD}/release" "${HELD}/records"
  [[ ! -d "${FAKE_GITHUB}/releases/$2" ]] || cp -R "${FAKE_GITHUB}/releases/$2" "${HELD}/release"
  [[ ! -d "$(record_folder "$1")" ]] || cp -R "$(record_folder "$1")" "${HELD}/records"
}
restore_state() {
  rm -rf "${FAKE_GITHUB}/releases/$2" "$(record_folder "$1")"
  [[ ! -d "${HELD}/release" ]] || cp -R "${HELD}/release" "${FAKE_GITHUB}/releases/$2"
  [[ ! -d "${HELD}/records" ]] || cp -R "${HELD}/records" "$(record_folder "$1")"
}

# Rewrites the records of the tag $1 to vouch for the release $2 as it now stands on the
# fixture's GitHub: what whoever changed a draft could also do. A publish that still
# refuses has read the tag and the draft's bytes, not the records. With no such release
# there is nothing to vouch for.
vouch_for() {
  local tag="$1" assets records
  assets="$(assets_of "$2")"
  records="$(record_folder "$1")"
  [[ -d "${assets}" ]] || return 0
  mkdir -p "${records}"
  cp "${assets}/$(zip_name "${tag}")" "${assets}/$(manifest_name "${tag}")" "${records}/"
  printf 'run 0\ncommit %s\nzip %s\nmanifest %s\n' "$(commit_of "${tag}")" \
    "$(rf_sha256 "${assets}/$(zip_name "${tag}")")" "$(rf_sha256 "${assets}/$(manifest_name "${tag}")")" > "${records}/checked"
  printf 'release %s\nzip %s\nmanifest %s\nsignature %s\n' "$2" "$(rf_sha256 "${assets}/$(zip_name "${tag}")")" \
    "$(rf_sha256 "${assets}/$(manifest_name "${tag}")")" "$(rf_sha256 "${assets}/$(signature_name "${tag}")")" > "${records}/reader-checked"
}

# Whether this file system makes a symlink when asked: Git Bash on Windows copies instead.
SYMLINKS=0
if ln -s "${WORK}/origin.git/HEAD" "${WORK}/symlink-probe" 2>/dev/null && [[ -L "${WORK}/symlink-probe" ]]; then
  SYMLINKS=1
fi
rm -f "${WORK}/symlink-probe"

# The fixture is built. From here a fixture step that fails is counted and the rows go on;
# the last row holds the count to zero.
fixture_failed() {
  # A command substitution's failure is its caller's to judge, as it was under set -e.
  [[ "${BASH_SUBSHELL}" -eq 0 ]] || return 0
  FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
  echo "  a fixture step failed at line $1"
}
set +e
set -E
trap 'fixture_failed "${LINENO}"' ERR

# A byte that would have a terminal act, and whether a run's output is free of it.
ESCAPE=$'\033'
no_escape() { lacks "$1" "${ESCAPE}"; }

echo "── every step: the environment and origin ──"
for step in check draft attach publish; do
  RUN_ENV=("GH_HOST=github.example.invalid")
  publish_release "${step}" v1.2.0
  RUN_ENV=()
  refused "${step} with GH_HOST set" "GH_HOST is set"
  check "${step} with GH_HOST set: asks GitHub nothing" equals "$(wc -l < "${FAKE_GITHUB}/gh.log" | tr -d ' ')" "0"
done
git -C "${REPO}" remote set-url origin "${WORK}/elsewhere.git"
for step in check draft attach publish; do
  publish_release "${step}" v1.2.0
  refused "${step} from another origin" "origin is "
  check "${step} from another origin: asks GitHub nothing" equals "$(wc -l < "${FAKE_GITHUB}/gh.log" | tr -d ' ')" "0"
done
git -C "${REPO}" remote set-url origin "${WORK}/origin.git"

echo "── check ──"
RECORDS="$(record_folder v1.2.0)"
ARTIFACT="${FAKE_GITHUB}/runs/7/artifacts/release-v1.2.0"
publish_release check v1.2.0
refused "no run on the tag has succeeded" "no release.yml run on the tag ref v1.2.0"
seed_run 7 v1.2.0
: > "${FAKE_GITHUB}/branches/v1.2.0"
publish_release check v1.2.0
refused "a branch named like the tag" "has a branch named v1.2.0"
rm "${FAKE_GITHUB}/branches/v1.2.0"
echo extra > "${ARTIFACT}/notes.txt"
publish_release check v1.2.0
refused "an artifact with a third file" "must hold $(zip_name v1.2.0) and $(manifest_name v1.2.0) only"
rm "${ARTIFACT}/notes.txt"
echo extra > "${ARTIFACT}/notes${ESCAPE}[2K.txt"
publish_release check v1.2.0
refused "an artifact with a file named to drive the terminal" "must hold $(zip_name v1.2.0) and $(manifest_name v1.2.0) only"
check "an artifact with a file named to drive the terminal: no escape byte is printed" no_escape "${OUT}"
rm "${ARTIFACT}/notes${ESCAPE}[2K.txt"
cp "${BUILT}/other.zip" "${ARTIFACT}/$(zip_name v1.2.0)"
publish_release check v1.2.0
refused "a zip that is not the tag's" "check-release-zip.mjs does not accept $(zip_name v1.2.0) for v1.2.0"
cp "${BUILT}/v1.2.0/$(zip_name v1.2.0)" "${ARTIFACT}/"
sed "s/${EXPIRES_AT}/$((EXPIRES_AT + 1))/" "${BUILT}/v1.2.0/$(manifest_name v1.2.0)" > "${ARTIFACT}/$(manifest_name v1.2.0)"
publish_release check v1.2.0
refused "a manifest that is not the one the tag and the zip give" "is not the manifest of that zip at v1.2.0"
check "no refused check leaves a record" no_file "${RECORDS}/checked"
cp "${BUILT}/v1.2.0/$(manifest_name v1.2.0)" "${ARTIFACT}/"
publish_release check v1.2.0
check "the built zip and manifest are checked" equals "${STATUS}" "0"
check "the record names the zip's SHA-256" contains "$(cat "${RECORDS}/checked" 2>/dev/null)" "zip $(rf_sha256 "${BUILT}/v1.2.0/$(zip_name v1.2.0)")"
check "the checked zip is kept" same_bytes "${RECORDS}/$(zip_name v1.2.0)" "${BUILT}/v1.2.0/$(zip_name v1.2.0)"
check "check writes nothing to GitHub" equals "$(gh_writes)" "0"

echo "── draft ──"
publish_release draft v1.2.1
refused "a tag that was not checked" "v1.2.1 has not been checked"
: > "${FAKE_GITHUB}/create-fails"
publish_release draft v1.2.0
check "a draft GitHub does not create: exit 2" equals "${STATUS}" "2"
check "a draft GitHub does not create: no folder is left for the signing account" equals "$(shared_count publish-release-)" "0"
rm "${FAKE_GITHUB}/create-fails"
RUN_ENV=("PUBLISH_RELEASE_HANDOFF_ROOT=${WORK}/no-such-folder")
publish_release draft v1.2.0
RUN_ENV=()
check "no folder to hand the zip over in: exit 2" equals "${STATUS}" "2"
check "no folder to hand the zip over in: no draft" equals "$(gh_writes)" "0"
publish_release draft v1.2.0
HANDOFF="$(shared_folder publish-release-v1.2.0.)"
check "a checked tag is drafted" equals "${STATUS}" "0"
check "one tag with one trust document: the draft holds the zip and the manifest only" equals "$(asset_list 100)" "$(manifest_name v1.2.0) $(zip_name v1.2.0) "
check "the draft's zip is the checked one" same_bytes "$(assets_of 100)/$(zip_name v1.2.0)" "${BUILT}/v1.2.0/$(zip_name v1.2.0)"
check "one new folder publish-release-<tag>.* holds the zip" same_bytes "${HANDOFF}/$(zip_name v1.2.0)" "${BUILT}/v1.2.0/$(zip_name v1.2.0)"
check "the folder is open to the signing account" equals "$(mode_of "${HANDOFF}")" "755"
check "the zip in it is readable and not writable by others" equals "$(mode_of "${HANDOFF}/$(zip_name v1.2.0)")" "644"
check "the sign command names that zip" contains "${OUT}" "scripts/sign-release.sh v1.2.0 ${HANDOFF}/$(zip_name v1.2.0) <private-key.pem>"
publish_release draft v1.2.0
refused "a tag that already has a draft" "a release for v1.2.0 is already on GitHub"
check "a refused draft leaves no second folder" equals "$(shared_count publish-release-v1.2.0.)" "1"

echo "── attach, with no folder named ──"
publish_release attach v1.2.0
refused "no folder from the sign" "no folder named sign-release-v1.2.0.*"
sign_release v1.2.0 "${HANDOFF}/$(zip_name v1.2.0)" "${KEYS}/release.pem" || true
SIGNED_1_2_0="${SIGNED_FOLDER:-}"
check "the copied sign-release.sh signs the handed-over zip" is_file "${SIGNED_1_2_0}/$(signature_name v1.2.0)"
# The sign's folder is looked for under the root the sign writes to, not under the root
# draft leaves the zip in.
mkdir "${WORK}/sign-root-without-a-folder"
RUN_ENV=("SIGN_RELEASE_OUT_ROOT=${WORK}/sign-root-without-a-folder")
publish_release attach v1.2.0
RUN_ENV=()
refused "a folder from the sign under the hand-off root only" "no folder named sign-release-v1.2.0.* under ${WORK}/sign-root-without-a-folder"
mkdir "${SHARED}/sign-release-v1.2.0.second"
publish_release attach v1.2.0
refused "two folders from the sign" "more than one folder named sign-release-v1.2.0.*"
check "two folders from the sign: both are named" contains "${OUT}" "${SHARED}/sign-release-v1.2.0.second"
rmdir "${SHARED}/sign-release-v1.2.0.second"
publish_release attach v1.2.0
check "the one folder from the sign is taken" equals "${STATUS}" "0"
check "its signature is uploaded once" equals "$(gh_calls "release upload")" "1"
check "the draft's signature is the folder's" same_bytes "$(assets_of 100)/$(signature_name v1.2.0)" "${SIGNED_1_2_0}/$(signature_name v1.2.0)"
check "the reader check is recorded for that draft" contains "$(cat "${RECORDS}/reader-checked" 2>/dev/null)" "release 100"
check "Godot 4.2 is asked once" equals "$(wc -l < "${FAKE_GITHUB}/godot-4.2.log" | tr -d ' ')" "1"
check "Godot 4.7 is asked once" equals "$(wc -l < "${FAKE_GITHUB}/godot-4.7.log" | tr -d ' ')" "1"
check "with one trust document the walk is handed the first and no other" \
  contains "$(cat "${FAKE_GITHUB}/godot-4.7.log")X" "/tag-trust/trust-1.json ${RECORDS}/tmp."
check "with one trust document the walk's arguments end at its own store" \
  contains "$(cat "${FAKE_GITHUB}/godot-4.7.log")X" "/walk-storeX"
# Only a name the sign's mktemp could give is the sign's folder. One that runs on into a
# line of its own would otherwise be printed, and read as a line this script wrote.
FORGED_LINE="${SHARED}/sign-release-v1.2.0.x"$'\n'"Attached a forged line."
mkdir "${FORGED_LINE}"
publish_release attach v1.2.0
check "a folder named with a line break beside the sign's: the sign's is taken" equals "${STATUS}" "0"
check "a folder named with a line break: its name is not printed" lacks "${OUT}" "Attached a forged line."
rmdir "${FORGED_LINE}"
if [[ "${SYMLINKS}" -eq 1 ]]; then
  ln -s "${SIGNED_1_2_0}" "${SHARED}/sign-release-v1.2.0.link"
  publish_release attach v1.2.0
  check "a symlink beside the sign's folder: the sign's is taken" equals "${STATUS}" "0"
  rm "${SHARED}/sign-release-v1.2.0.link"
  mkdir "${WORK}/sign-root-with-a-symlink" "${WORK}/linked-signature"
  ln -s "${SIGNED_1_2_0}" "${WORK}/sign-root-with-a-symlink/sign-release-v1.2.0.link"
  RUN_ENV=("SIGN_RELEASE_OUT_ROOT=${WORK}/sign-root-with-a-symlink")
  publish_release attach v1.2.0
  RUN_ENV=()
  refused "a symlink alone under the sign root" "no folder named sign-release-v1.2.0.* under ${WORK}/sign-root-with-a-symlink"
  cp "${SIGNED_1_2_0}/$(manifest_name v1.2.0)" "${WORK}/linked-signature/"
  ln -s "${SIGNED_1_2_0}/$(signature_name v1.2.0)" "${WORK}/linked-signature/$(signature_name v1.2.0)"
  publish_release attach v1.2.0 "${WORK}/linked-signature"
  refused "a named folder whose signature is a symlink" "${WORK}/linked-signature holds no $(signature_name v1.2.0)"
else
  skip "a symlink beside the sign's folder, a symlink alone and a signature that is a symlink: this file system makes no symlinks"
fi

echo "── publish, one trust document ──"
publish_release publish v1.2.0
check "a draft that passes every check is published" equals "${STATUS}" "0"
check "it is published once, as the latest" equals "$(grep -c -x -F "release edit v1.2.0 --repo ${FAKE_SLUG} --draft=false --latest" "${FAKE_GITHUB}/gh.log" || true)" "1"
check "an anonymous reader is asked for the latest release" equals "$(wc -l < "${FAKE_GITHUB}/curl.log" | tr -d ' ')" "1"
check "the ledger line is printed" contains "${OUT}" "  1.2.0 $(rf_sha256 "${BUILT}/v1.2.0/$(manifest_name v1.2.0)")"
publish_release publish v1.2.0
check "a published release is checked again" equals "${STATUS}" "0"
check "a published release is not published twice" equals "$(gh_writes)" "0"
check "a published release: the run says so" contains "${OUT}" "v1.2.0 is already published; checking it again."
publish_release attach v1.2.0 "${SIGNED_1_2_0}"
refused "attach: a release that is already published" "v1.2.0 is already published."

echo "── two trust documents: check, draft, attach ──"
RECORDS="$(record_folder v1.2.1)"
seed_run 8 v1.2.1
seed_run 9 v1.3.0
publish_release check v1.2.1
check "check passes for the tag with two documents" equals "${STATUS}" "0"
publish_release check v1.3.0
# A folder an earlier draft of the tag left holds a zip the signing account could sign.
STALE="${SHARED}/publish-release-v1.3.0.stale"
mkdir "${STALE}"
publish_release draft v1.3.0
refused "draft: a hand-off folder an earlier draft left" "an earlier hand-off folder for v1.3.0 is still there: ${STALE}"
check "draft: the earlier hand-off folder is left as it was" is_folder "${STALE}"
check "draft: no second hand-off folder is made beside it" equals "$(shared_count publish-release-v1.3.0.)" "1"
rmdir "${STALE}"
publish_release draft v1.3.0
refused "draft: a first trust document that is not the pinned one" "the first trust document is pinned to"
check "draft: a refused tag leaves no folder for the signing account" equals "$(shared_count publish-release-v1.3.0.)" "0"
publish_release draft v1.2.1
HANDOFF="$(shared_folder publish-release-v1.2.1.)"
check "the tag with two documents is drafted" equals "${STATUS}" "0"
check "the draft carries trust-2.json and not trust-1.json" equals "$(asset_list 101)" "$(manifest_name v1.2.1) $(zip_name v1.2.1) trust-2.json "
check "the draft's trust-2.json is the tag's" same_bytes "$(assets_of 101)/trust-2.json" "${SECOND}"
sign_release v1.2.1 "${HANDOFF}/$(zip_name v1.2.1)" "${KEYS}/release.pem" || true
SIGNED_1_2_1="${SIGNED_FOLDER:-}"
check "the copied sign-release.sh signs for the tag with two documents" is_file "${SIGNED_1_2_1}/$(signature_name v1.2.1)"
keep_state v1.2.1 101

FORGED="${WORK}/forged"
mkdir "${FORGED}"
sed "s/${EXPIRES_AT}/$((EXPIRES_AT + 1))/" "${BUILT}/v1.2.1/$(manifest_name v1.2.1)" > "${FORGED}/$(manifest_name v1.2.1)"
sign_bytes "${KEYS}/release.pem" "${FORGED}/$(manifest_name v1.2.1)" "${FORGED}/$(signature_name v1.2.1)"
publish_release attach v1.2.1 "${FORGED}"
refused "attach: a folder whose manifest is not the checked one" "is not the one check passed for v1.2.1"
cp "${BUILT}/v1.2.1/$(manifest_name v1.2.1)" "${FORGED}/"
sign_bytes "${KEYS}/unlisted.pem" "${FORGED}/$(manifest_name v1.2.1)" "${FORGED}/$(signature_name v1.2.1)"
publish_release attach v1.2.1 "${FORGED}"
refused "attach: a signature from a key the tag does not list" "--verify does not accept the signature"
restore_state v1.2.1 101

rm "$(assets_of 101)/trust-2.json"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a draft with a trust document missing" "must hold the zip, the manifest, trust-2.json and at most the signature"
restore_state v1.2.1 101
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 101)/trust-3.json"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a draft with a trust document the tag does not hold" "must hold the zip, the manifest, trust-2.json and at most the signature"
restore_state v1.2.1 101
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 101)/trust-2.json"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a trust document that differs from the tag's" "the release's trust-2.json is not v1.2.1's trust/trust-2.json"
restore_state v1.2.1 101
# The latest release is v1.2.0, published above. A trust-2.json there with other bytes is
# a document the draft would change.
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 100)/trust-2.json"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a trust document of the latest release changed" "the latest release v1.2.0 carries trust-2.json"
rm "$(assets_of 100)/trust-2.json"
mv "${FAKE_GITHUB}/releases/101" "${HELD}/away"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: no draft" "v1.2.1 has no draft: run scripts/publish-release.sh draft v1.2.1 first."
mv "${HELD}/away" "${FAKE_GITHUB}/releases/101"
: > "${FAKE_GITHUB}/releases/101/prerelease"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a draft marked a pre-release" "the draft for v1.2.1 is marked a pre-release; clear it on GitHub."
restore_state v1.2.1 101
: > "${FAKE_GITHUB}/assets-unread"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
check "attach: the draft's assets unread: exit 2" equals "${STATUS}" "2"
check "attach: the draft's assets unread: says so" contains "${OUT}" "error: could not read the assets of the draft for v1.2.1."
check "attach: the draft's assets unread: nothing is uploaded" equals "$(gh_writes)" "0"
rm "${FAKE_GITHUB}/assets-unread"
cp "${BUILT}/other.zip" "$(assets_of 101)/$(zip_name v1.2.1)"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a draft whose zip is not the checked one" "the draft for v1.2.1 does not hold the zip and manifest that were checked"
restore_state v1.2.1 101
sign_bytes "${KEYS}/unlisted.pem" "${BUILT}/v1.2.1/$(manifest_name v1.2.1)" "$(assets_of 101)/$(signature_name v1.2.1)"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
refused "attach: a signature already on the draft that is not the folder's" "the draft's $(signature_name v1.2.1) is not the one in ${SIGNED_1_2_1}"
restore_state v1.2.1 101

RUN_ENV=("GODOT_BIN_4_7=${STUB}/godot-4.2")
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
RUN_ENV=()
check "attach: a binary of another Godot version: exit 2" equals "${STATUS}" "2"
check "attach: a binary of another Godot version: nothing is uploaded" equals "$(gh_writes)" "0"
echo "the walk refuses trust-2.json: a reason from the fixture ${ESCAPE}[2K" > "${FAKE_GITHUB}/godot-4.7.says"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
check "attach: a reader walk that fails on one Godot: refused" equals "${STATUS}" "1"
check "attach: a reader walk that fails: names the version" contains "${OUT}" "refused: on Godot 4.7,"
check "attach: a reader walk that fails: shows the reader's reason" contains "${OUT}" "the walk refuses trust-2.json: a reason from the fixture"
check "attach: a reader walk that fails: no escape byte of the reader's is printed" no_escape "${OUT}"
check "attach: a reader walk that fails: no reader check is recorded" no_file "${RECORDS}/reader-checked"
rm "${FAKE_GITHUB}/godot-4.7.says"
publish_release attach v1.2.1 "${SIGNED_1_2_1}"
check "attach with the folder named passes" equals "${STATUS}" "0"
check "a signature already on the draft is not uploaded again" equals "$(gh_writes)" "0"
check "the draft holds the signature beside the documents" equals "$(asset_list 101)" "$(manifest_name v1.2.1) $(signature_name v1.2.1) $(zip_name v1.2.1) trust-2.json "
for minor in 4.2 4.7; do
  check "Godot ${minor}: the walk starts from the tag's trust-1.json and its own store" \
    contains "$(cat "${FAKE_GITHUB}/godot-${minor}.log")" "/tag-trust/trust-1.json ${RECORDS}/tmp."
  check "Godot ${minor}: the walk is handed the draft's trust-2.json, downloaded back" \
    contains "$(cat "${FAKE_GITHUB}/godot-${minor}.log")X" "/walk-store ${RECORDS}/tmp."
  check "Godot ${minor}: trust-2.json is the last argument" \
    contains "$(cat "${FAKE_GITHUB}/godot-${minor}.log")X" "/draft/trust-2.jsonX"
done

echo "── publish refuses: the checkout, the tag and its trust documents ──"
keep_state v1.2.1 101
RUN_ENV=("NODE_OPTIONS=")
publish_release publish v1.2.1
RUN_ENV=()
refused "a refused variable set to nothing" "NODE_OPTIONS is set"
# A tool the checks run is looked for before anything is read.
mv "${REPO}/scripts/check-release-zip.mjs" "${HELD}/check-release-zip.mjs"
publish_release publish v1.2.1
check "publish with no check-release-zip.mjs: exit 2" equals "${STATUS}" "2"
check "publish with no check-release-zip.mjs: says so" contains "${OUT}" "error: scripts/check-release-zip.mjs is missing."
check "publish with no check-release-zip.mjs: asks GitHub nothing" equals "$(gh_asked)" "0"
mv "${HELD}/check-release-zip.mjs" "${REPO}/scripts/check-release-zip.mjs"
echo stray > "${REPO}/stray.txt"
publish_release publish v1.2.1
refused "an untracked file in the checkout" "has changed or untracked files"
rm "${REPO}/stray.txt"
repo_git commit -q --allow-empty -m "a commit origin does not have"
publish_release publish v1.2.1
refused "a checkout ahead of origin's main" "not the tip of origin's main"
repo_git reset -q --hard HEAD~1
TAG_OBJECT="$(git -C "${REPO}" rev-parse refs/tags/v1.2.1)"
repo_git tag -f -a -m moved v1.2.1 "$(commit_of v1.2.0)" >/dev/null
publish_release publish v1.2.1
refused "a tag that is another commit on origin" "in this checkout and"
git -C "${REPO}" update-ref refs/tags/v1.2.1 "${TAG_OBJECT}"
publish_release publish v1.4.0
refused "a tag whose commit is not on main" "is not on origin's main"
publish_release publish v1.3.0
refused "a first trust document that is not the pinned one" "the first trust document is pinned to"

echo "── publish refuses: the draft ──"
# From here each row changes the draft, has the records vouch for the change, and puts
# both back.
mv "${FAKE_GITHUB}/releases/101" "${HELD}/away"
publish_release publish v1.2.1
refused "no draft" "v1.2.1 has no draft"
mv "${HELD}/away" "${FAKE_GITHUB}/releases/101"
cp -R "${FAKE_GITHUB}/releases/101" "${FAKE_GITHUB}/releases/102"
publish_release publish v1.2.1
refused "two drafts for the tag" "more than one release carries the tag v1.2.1"
rm -rf "${FAKE_GITHUB}/releases/102"
rm "${RECORDS}/reader-checked"
publish_release publish v1.2.1
refused "no reader check on record" "the reader check has not passed for v1.2.1"
restore_state v1.2.1 101
# The same draft under another id: one that was deleted and made again since the attach.
mv "${FAKE_GITHUB}/releases/101" "${FAKE_GITHUB}/releases/103"
publish_release publish v1.2.1
refused "another draft than the reader check passed for" "the release for v1.2.1 is not the draft the reader check passed for"
mv "${FAKE_GITHUB}/releases/103" "${FAKE_GITHUB}/releases/101"
{ grep -v '^signature ' "${HELD}/records/reader-checked"; echo "signature 0"; } > "${RECORDS}/reader-checked"
publish_release publish v1.2.1
refused "a signature the reader check did not pass for" "the release's $(signature_name v1.2.1) is not the one the reader check passed for"
restore_state v1.2.1 101
: > "${FAKE_GITHUB}/releases/101/prerelease"
publish_release publish v1.2.1
refused "a draft marked a pre-release" "the draft for v1.2.1 is marked a pre-release; clear it on GitHub."
restore_state v1.2.1 101
echo 100 > "${FAKE_GITHUB}/latest"
: > "${FAKE_GITHUB}/assets-unread"
publish_release publish v1.2.1
check "the draft's assets unread: exit 2" equals "${STATUS}" "2"
check "the draft's assets unread: says so" contains "${OUT}" "error: could not read the assets of the release for v1.2.1."
check "the draft's assets unread: writes nothing to GitHub" equals "$(gh_writes)" "0"
rm "${FAKE_GITHUB}/assets-unread"
EXPECTED_SET="must hold the zip, the manifest, the signature and trust-2.json, and nothing else"
rm "$(assets_of 101)/trust-2.json"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a trust document missing" "${EXPECTED_SET}"
restore_state v1.2.1 101
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 101)/trust-3.json"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a trust document the tag does not hold" "${EXPECTED_SET}"
restore_state v1.2.1 101
echo notes > "$(assets_of 101)/notes.txt"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "an asset that is none of the release's" "${EXPECTED_SET}"
restore_state v1.2.1 101
cp "${BUILT}/other.zip" "$(assets_of 101)/$(zip_name v1.2.1)"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a zip that is not the tag's, vouched for by the records" "check-release-zip.mjs does not accept $(zip_name v1.2.1) for v1.2.1"
restore_state v1.2.1 101
sed "s/${EXPIRES_AT}/$((EXPIRES_AT + 1))/" "${BUILT}/v1.2.1/$(manifest_name v1.2.1)" > "$(assets_of 101)/$(manifest_name v1.2.1)"
sign_bytes "${KEYS}/release.pem" "$(assets_of 101)/$(manifest_name v1.2.1)" "$(assets_of 101)/$(signature_name v1.2.1)"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a manifest the tag and the zip do not give, signed by the release key" "is not the manifest of its zip at v1.2.1"
restore_state v1.2.1 101
# A draft's manifest is shown beside the expected one, and its bytes are not this script's.
printf '{"format": 1, "version": "%s[2K1.2.1"}\n' "${ESCAPE}" > "$(assets_of 101)/$(manifest_name v1.2.1)"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a manifest written to drive the terminal" "is not the manifest of its zip at v1.2.1"
check "a manifest written to drive the terminal: no escape byte is printed" no_escape "${OUT}"
restore_state v1.2.1 101
sign_bytes "${KEYS}/unlisted.pem" "$(assets_of 101)/$(manifest_name v1.2.1)" "$(assets_of 101)/$(signature_name v1.2.1)"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a signature from a key the tag does not list" "--verify does not accept the release's $(signature_name v1.2.1)"
restore_state v1.2.1 101
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 101)/trust-2.json"
vouch_for v1.2.1 101
publish_release publish v1.2.1
refused "a trust document that differs from the tag's" "the release's trust-2.json is not v1.2.1's trust/trust-2.json"
restore_state v1.2.1 101

echo "── publish refuses: the repository ──"
# The latest release carries a trust-3.json, which the draft would drop.
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 100)/trust-3.json"
publish_release publish v1.2.1
refused "a trust document of the latest release dropped" "the latest release v1.2.0 carries trust-3.json"
rm "$(assets_of 100)/trust-3.json"
# And a trust-2.json with other bytes, which the draft would change.
cp "${NOT_A_TAGS_DOCUMENT}" "$(assets_of 100)/trust-2.json"
publish_release publish v1.2.1
refused "a trust document of the latest release changed" "the latest release v1.2.0 carries trust-2.json"
rm "$(assets_of 100)/trust-2.json"
echo false > "${FAKE_GITHUB}/immutable-releases"
publish_release publish v1.2.1
refused "immutable releases off" "immutable releases are not on for ${FAKE_SLUG}"
mv "${FAKE_GITHUB}/immutable-releases" "${HELD}/immutable-releases"
publish_release publish v1.2.1
check "the immutable releases setting unread: exit 2" equals "${STATUS}" "2"
check "the immutable releases setting unread: says so" contains "${OUT}" "error: could not read whether immutable releases are on for ${FAKE_SLUG}."
check "the immutable releases setting unread: writes nothing to GitHub" equals "$(gh_writes)" "0"
mv "${HELD}/immutable-releases" "${FAKE_GITHUB}/immutable-releases"
echo true > "${FAKE_GITHUB}/immutable-releases"
seed_published 5 v2.0.0
echo 5 > "${FAKE_GITHUB}/latest"
publish_release publish v1.2.1
refused "a latest release of a higher version" "the latest release is v2.0.0, which is not below v1.2.1"
# 2^64 + 1, which 64-bit arithmetic reads as 1.
echo v18446744073709551617.0.0 > "${FAKE_GITHUB}/releases/5/tag"
publish_release publish v1.2.1
refused "a latest release with a number past 64 bits" "the latest release is v18446744073709551617.0.0, which is not below v1.2.1"
restore_state v1.2.1 101
echo 5 > "${FAKE_GITHUB}/latest"
echo nightly > "${FAKE_GITHUB}/releases/5/tag"
publish_release publish v1.2.1
refused "a latest release that is no version" "the latest release is nightly, which is not a version"
rm -rf "${FAKE_GITHUB}/releases/5"
# No published release at all: the two the fixture has are taken away.
mv "${FAKE_GITHUB}/releases/1" "${HELD}/release-1"
mv "${FAKE_GITHUB}/releases/100" "${HELD}/release-100"
publish_release publish v1.2.1
refused "a repository with no published release" "shows no published release"
mv "${HELD}/release-1" "${FAKE_GITHUB}/releases/1"
mv "${HELD}/release-100" "${FAKE_GITHUB}/releases/100"
echo 100 > "${FAKE_GITHUB}/latest"

echo "── publish: an asset added to the draft late ──"
# GitHub has no call that checks a draft and publishes it as one step. An asset added
# before the last read of the draft stops the publish.
echo 101 > "${FAKE_GITHUB}/asset-added-at-setting-read"
publish_release publish v1.2.1
refused "an asset added while the draft was being checked" "the draft for v1.2.1 changed while it was being checked"
rm "${FAKE_GITHUB}/asset-added-at-setting-read"
restore_state v1.2.1 101
echo 100 > "${FAKE_GITHUB}/latest"
# One added after that read is published with the release, and the checks that follow say so.
: > "${FAKE_GITHUB}/asset-added-at-publish"
publish_release publish v1.2.1
check "an asset added with the publish: exit 1" equals "${STATUS}" "1"
check "an asset added with the publish: a failed line names the assets" contains "${OUT}" "FAIL: the release must hold the zip, the manifest, the signature and trust-2.json, and nothing else; it holds: "
check "an asset added with the publish: the line names the added one" contains "${OUT}" "late.txt"
check "an asset added with the publish: the run says the release cannot be withdrawn" contains "${OUT}" "v1.2.1 is published, and a check on it failed"
rm "${FAKE_GITHUB}/asset-added-at-publish"
restore_state v1.2.1 101
echo 100 > "${FAKE_GITHUB}/latest"

echo "── publish, two trust documents ──"
publish_release publish v1.2.1
check "the draft with its trust document is published" equals "${STATUS}" "0"
check "it is published once, as the latest" equals "$(grep -c -x -F "release edit v1.2.1 --repo ${FAKE_SLUG} --draft=false --latest" "${FAKE_GITHUB}/gh.log" || true)" "1"
check "the published trust-2.json is checked against the release's attestation" equals "$(gh_calls "release verify-asset v1.2.1 .*/trust-2.json")" "1"
check "the fixture's GitHub now has it as the latest" equals "$(cat "${FAKE_GITHUB}/latest")" "101"
publish_release publish v1.2.1
check "published and run again: checked, not published twice" equals "${STATUS} $(gh_writes)" "0 0"

echo "── every call names the repository ──"
check "no call to gh or curl left the repository unnamed" equals "${NOT_NAMED}" "0"

echo "── the fixture's steps ──"
check "every fixture step between the rows succeeded" equals "${FIXTURE_FAILURES}" "0"

echo
echo "${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
# The exit status below is the verdict, not a fixture step.
trap - ERR
[[ "${FAILED}" -eq 0 ]]
