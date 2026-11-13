# shellcheck shell=bash
#
# scripts/lib/release_checks.sh: the checks a release passes before it is signed or
# published, and the update manifest a tag and a zip give.
#
# Sourced, never run, by a script that has set REPO_ROOT to the checkout it sits in. A
# check compares only what git reads at REPO_ROOT, what origin answers to git ls-remote,
# and the values pinned in release_identity.sh. One that refuses prints a single
# "refused: <reason>" line on stderr and returns 1. None exits, so the caller decides what
# a refusal ends.
#
#   rc_printable                  filter: each byte that is not printable ASCII or a line
#                                 break becomes "?"
#   rc_check_environment          refuse while a variable in RC_REFUSED_VARIABLES is set,
#                                 even to nothing
#   rc_check_origin               refuse unless origin is RELEASE_ORIGIN_URL
#   rc_check_head                 refuse a checkout with changed or untracked files, or
#                                 one not at the tip of origin's RELEASE_BRANCH; sets
#                                 RC_REMOTE_HEAD to that tip
#   rc_check_tag <tag>            refuse unless origin's <tag> is this checkout's and its
#                                 commit is on that branch; sets RC_COMMIT to the commit.
#                                 Needs rc_check_head.
#   rc_check_trust <tag> <dir>    refuse unless the tag's trust documents run from
#                                 trust-1.json to trust-N.json, the first is the pinned
#                                 one, each verifies against the one before it, and the
#                                 toolkit at the tag embeds the last; leaves each as
#                                 <dir>/trust-K.json and sets RC_TRUST_N to N
#   rc_checks_1_to_6 <tag> <dir>  the five above, in that order, stopping at a refusal
#   rc_check_zip <tag> <zip>      refuse unless scripts/check-release-zip.mjs accepts
#                                 <zip> for the tag
#   rc_expected_manifest <tag> <zip> <out>
#                                 write to <out> the update manifest of <zip> at <tag>,
#                                 from the tag's constants and its commit time; <zip>'s
#                                 file name becomes the manifest's archive

# shellcheck source=release_identity.sh
source "${REPO_ROOT}/scripts/lib/release_identity.sh"
# shellcheck source=release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"
# shellcheck source=compatible_server.sh
source "${REPO_ROOT}/scripts/lib/compatible_server.sh"

RC_RELEASE_TAG='^v[0-9]+\.[0-9]+\.[0-9]+$'
RC_OBJECT_NAME='^[0-9a-f]{40,64}$'
# Nine digits fit bash's arithmetic on every build and outrun any real document number.
RC_TRUST_DOCUMENT_PATH='^trust/trust-([1-9][0-9]{0,8})\.json$'
RC_EMBEDDED_FILE="addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd"
RC_EMBEDDED_MARKER="const DOCUMENT := "
# The variables that aim gh, node, openssl or git at another repository, host,
# configuration, history, certificate or program. No list of names is complete, so a
# caller that must be sure starts a release script from an empty environment (env -i);
# this list refuses what that would have dropped.
RC_REFUSED_VARIABLES=(
  GH_REPO GH_HOST NODE_OPTIONS NODE_PATH OPENSSL_CONF SSL_CERT_FILE SSL_CERT_DIR
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL
  GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_SSL_NO_VERIFY GIT_SSL_CAINFO
  GIT_SSL_CAPATH GIT_SSH_COMMAND GIT_PROXY_COMMAND GIT_GRAFT_FILE GIT_SHALLOW_FILE
  GIT_REPLACE_REF_BASE
)

rc_refuse() {
  echo "refused: $*" >&2
}

# Replaces with "?" each byte of the text on stdin that is not printable ASCII or a line
# break, so a commit's subject, a file's name or a tool's output cannot drive the terminal
# it is shown on. LC_ALL=C has tr take the input byte by byte, whatever the locale.
rc_printable() {
  LC_ALL=C tr -c '\n\040-\176' '?'
}

# Prints the object name the listing $1, git ls-remote's answer, gives the ref $2. git
# matches a pattern against the tail of a ref's name, so an answer can hold other refs
# than the one asked for.
rc_listed_object() {
  printf '%s\n' "$1" | awk -v ref="$2" '$2 == ref { print $1 }'
}

# The reason a tool gave for failing: the last line of its output $1.
rc_reason() {
  printf '%s\n' "$1" | tr -d '\r' | tail -n 1 | sed 's/^error: //'
}

rc_check_environment() {
  local name
  for name in "${RC_REFUSED_VARIABLES[@]}"; do
    if declare -p "${name}" >/dev/null 2>&1; then
      rc_refuse "${name} is set; a release is checked with none of these set: ${RC_REFUSED_VARIABLES[*]}."
      return 1
    fi
  done
}

rc_check_origin() {
  local url
  url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null | tr -d '\r')" || url=""
  if [[ "${url}" != "${RELEASE_ORIGIN_URL}" ]]; then
    rc_refuse "origin is ${url:-not set}, not ${RELEASE_ORIGIN_URL}."
    return 1
  fi
}

rc_check_head() {
  local changes listing head
  RC_REMOTE_HEAD=""
  if ! changes="$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=normal 2>/dev/null)"; then
    rc_refuse "could not read the state of the checkout at ${REPO_ROOT}."
    return 1
  fi
  if [[ -n "${changes}" ]]; then
    rc_refuse "the checkout at ${REPO_ROOT} has changed or untracked files."
    return 1
  fi
  listing="$(git -C "${REPO_ROOT}" ls-remote origin "refs/heads/${RELEASE_BRANCH}" 2>/dev/null | tr -d '\r')" || listing=""
  RC_REMOTE_HEAD="$(rc_listed_object "${listing}" "refs/heads/${RELEASE_BRANCH}")"
  if [[ ! "${RC_REMOTE_HEAD}" =~ ${RC_OBJECT_NAME} ]]; then
    RC_REMOTE_HEAD=""
    rc_refuse "could not read the tip of ${RELEASE_BRANCH} from origin."
    return 1
  fi
  head="$(git -C "${REPO_ROOT}" rev-parse -q --verify "HEAD^{commit}" 2>/dev/null | tr -d '\r')" || head=""
  if [[ "${head}" != "${RC_REMOTE_HEAD}" ]]; then
    rc_refuse "HEAD is ${head:-unreadable}, not the tip of origin's ${RELEASE_BRANCH}, ${RC_REMOTE_HEAD}."
    return 1
  fi
}

rc_check_tag() {
  local tag="$1" ref="refs/tags/$1" listing remote local_commit
  RC_COMMIT=""
  if [[ ! "${tag}" =~ ${RC_RELEASE_TAG} ]]; then
    rc_refuse "${tag} is no release tag; one reads v<major>.<minor>.<patch>."
    return 1
  fi
  listing="$(git -C "${REPO_ROOT}" ls-remote origin "${ref}" "${ref}^{}" 2>/dev/null | tr -d '\r')" || listing=""
  # An annotated tag is listed twice, and the ^{} line names the commit it points at. A
  # lightweight tag has only its own line, which already names the commit.
  remote="$(rc_listed_object "${listing}" "${ref}^{}")"
  [[ -n "${remote}" ]] || remote="$(rc_listed_object "${listing}" "${ref}")"
  if [[ ! "${remote}" =~ ${RC_OBJECT_NAME} ]]; then
    rc_refuse "origin has no tag ${tag}, or did not answer."
    return 1
  fi
  local_commit="$(git -C "${REPO_ROOT}" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null | tr -d '\r')" || local_commit=""
  if [[ -z "${local_commit}" ]]; then
    rc_refuse "this checkout has no tag ${tag}."
    return 1
  fi
  if [[ "${local_commit}" != "${remote}" ]]; then
    rc_refuse "the tag ${tag} is ${local_commit} in this checkout and ${remote} on origin."
    return 1
  fi
  if ! git -C "${REPO_ROOT}" merge-base --is-ancestor "${local_commit}" "${RC_REMOTE_HEAD}" 2>/dev/null; then
    rc_refuse "the commit of ${tag}, ${local_commit}, is not on origin's ${RELEASE_BRANCH}."
    return 1
  fi
  RC_COMMIT="${local_commit}"
}

rc_check_trust() {
  local tag="$1" dir="$2" ref="refs/tags/$1" path number count=0 highest=0 hash output embedded literal
  RC_TRUST_N=""
  if ! git -C "${REPO_ROOT}" rev-parse -q --verify "${ref}^{commit}" >/dev/null 2>&1; then
    rc_refuse "there is no tag ${tag} to read trust documents from."
    return 1
  fi
  while IFS= read -r path; do
    if [[ "${path}" =~ ${RC_TRUST_DOCUMENT_PATH} ]]; then
      count=$((count + 1))
      (( BASH_REMATCH[1] <= highest )) || highest="${BASH_REMATCH[1]}"
    # git quotes a name it finds unusual, so the closing quote is allowed for.
    elif [[ "${path%\"}" == *trust/trust-*.json ]]; then
      rc_refuse "the tag ${tag} holds ${path}, which is named like a trust document and is none."
      return 1
    fi
  done < <(git -C "${REPO_ROOT}" ls-tree --name-only "${ref}" trust/ 2>/dev/null | tr -d '\r')
  if (( highest == 0 )); then
    rc_refuse "the tag ${tag} holds no trust document."
    return 1
  fi
  if (( count != highest )); then
    rc_refuse "the tag ${tag} holds ${count} trust documents up to trust-${highest}.json; they must run from trust-1.json with no gap."
    return 1
  fi
  mkdir -p "${dir}"
  for (( number = 1; number <= highest; number++ )); do
    if ! git -C "${REPO_ROOT}" show "${ref}:trust/trust-${number}.json" > "${dir}/trust-${number}.json" 2>/dev/null; then
      rc_refuse "could not read trust/trust-${number}.json at ${tag}."
      return 1
    fi
  done

  hash="$(rf_sha256 "${dir}/trust-1.json")"
  if [[ "${hash}" != "${RELEASE_TRUST_1_SHA256}" ]]; then
    rc_refuse "trust-1.json at ${tag} has the SHA-256 ${hash}; the first trust document is pinned to ${RELEASE_TRUST_1_SHA256}."
    return 1
  fi
  # The verifier is this checkout's, never the tag's: a tag cannot bring its own rules. A
  # caller's stdin may hold a passphrase, so the verifier gets none of it.
  if ! output="$(bash "${REPO_ROOT}/scripts/trust-document.sh" verify --first "${dir}/trust-1.json" 2>&1 < /dev/null)"; then
    rc_refuse "trust-1.json at ${tag} does not verify: $(rc_reason "${output}")"
    return 1
  fi
  for (( number = 2; number <= highest; number++ )); do
    if ! output="$(bash "${REPO_ROOT}/scripts/trust-document.sh" verify "${dir}/trust-$((number - 1)).json" "${dir}/trust-${number}.json" 2>&1 < /dev/null)"; then
      rc_refuse "trust-${number}.json at ${tag} does not verify against trust-$((number - 1)).json: $(rc_reason "${output}")"
      return 1
    fi
  done

  # The toolkit holds its document as one line, const DOCUMENT := '<the file's text>',
  # without the file's final newline.
  embedded="$(git -C "${REPO_ROOT}" show "${ref}:${RC_EMBEDDED_FILE}" 2>/dev/null | tr -d '\r' | grep -F "${RC_EMBEDDED_MARKER}")" || embedded=""
  literal="${embedded#"${RC_EMBEDDED_MARKER}'"}"
  literal="${literal%"'"}"
  if [[ "${embedded}" != "${RC_EMBEDDED_MARKER}'${literal}'" ]] \
    || ! printf '%s\n' "${literal}" | cmp -s - "${dir}/trust-${highest}.json"; then
    rc_refuse "the toolkit at ${tag} does not embed trust-${highest}.json: the DOCUMENT constant of ${RC_EMBEDDED_FILE} must hold that file's text."
    return 1
  fi
  RC_TRUST_N="${highest}"
}

rc_checks_1_to_6() {
  rc_check_environment || return 1
  rc_check_origin || return 1
  rc_check_head || return 1
  rc_check_tag "$1" || return 1
  rc_check_trust "$1" "$2" || return 1
}

rc_check_zip() {
  local tag="$1" zip="$2" folder
  if ! folder="$(cd "$(dirname "${zip}")" 2>/dev/null && pwd)"; then
    rc_refuse "no zip at ${zip}."
    return 1
  fi
  zip="${folder}/$(basename "${zip}")"
  # The check reads the tag through git in its working directory. A caller's stdin may
  # hold a passphrase, so node gets none of it. The zip names its own entries, so what the
  # check prints is filtered; pipefail is set here because the filter's status would
  # otherwise stand for the check's.
  if ! (set -o pipefail; cd "${REPO_ROOT}" && node "${REPO_ROOT}/scripts/check-release-zip.mjs" "${zip}" "${tag}" < /dev/null 2>&1 | rc_printable >&2); then
    rc_refuse "scripts/check-release-zip.mjs does not accept $(basename "${zip}") for ${tag}."
    return 1
  fi
}

rc_expected_manifest() {
  local tag="$1" zip="$2" out="$3" ref="refs/tags/$1" tag_root="$3.tag" min_godot compatible_server committed
  # The readers of both constants take a repository root, so the tag's file goes under one.
  mkdir -p "$(dirname "${tag_root}/${CS_CONSTANT_FILE}")"
  git -C "${REPO_ROOT}" show "${ref}:${CS_CONSTANT_FILE}" > "${tag_root}/${CS_CONSTANT_FILE}" 2>/dev/null || true
  min_godot="$(rf_min_godot "${tag_root}")" || min_godot=""
  compatible_server="$(cs_current "${tag_root}")" || compatible_server=""
  rm -rf "${tag_root}"
  committed="$(git -C "${REPO_ROOT}" log -1 --format=%ct "${ref}^{commit}" 2>/dev/null | tr -d '\r')" || committed=""
  if [[ -z "${min_godot}" || -z "${compatible_server}" || ! "${committed}" =~ ^[0-9]+$ ]]; then
    rc_refuse "could not read the manifest's fields from ${tag}."
    return 1
  fi
  # The expiry counts from the tag's commit, as rf_expires_at counts from HEAD in the build.
  rf_write_manifest "${zip}" "${tag#v}" "${min_godot}" "${compatible_server}" \
    "$((committed + RF_EXPIRY_SECONDS))" "${out}"
}
