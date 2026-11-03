#!/usr/bin/env bash
# Build, sign, verify and print the trust documents behind self-update's chain of keys.
#
# A document file is {"document": "<base64>", "signatures": ["<base64>", ...]}. The decoded
# document is {"format": 1, "version": N, "root_keys": [pem, ...], "root_threshold": T,
# "release_keys": [pem, ...]}, and each signature is RSA with SHA-256 over the decoded bytes.
# A bad document stops every client for good, so verify holds a file to the rules of the
# reader that clients run (addons/godot_mcp_toolkit/self_update/trust_chain.gd), and where the
# reader only ignores something a document should never hold, such as a release key that does
# not load, verify refuses it. It needs bash, openssl and awk, and no network.
#
# Usage:
#   scripts/trust-document.sh build --first --add-root <pem> [--add-root <pem>]
#         [--add-release <pem>] [--threshold T] [--out <folder>]
#       write trust-1.json, unsigned, in <folder> (the repo's trust/ by default). The threshold
#       starts at 1.
#   scripts/trust-document.sh build <previous> [--add-release <pem>] [--drop-release <pem>]
#         [--add-root <pem>] [--drop-root <pem>] [--threshold T] [--out <folder>]
#       write the next document, unsigned, beside <previous> or in <folder>. A key is a PEM
#       public key, matched by its content rather than its layout. The threshold stays as it
#       was unless given. Dropping every release key stops all updates.
#   scripts/trust-document.sh sign <document> <private-key.pem>
#       add one signature to <document>, refusing a non-RSA key. Pipe an encrypted key's
#       passphrase in on stdin; without a pipe, openssl prompts once. A next document needs a
#       threshold of the previous roots and a threshold of its own.
#   scripts/trust-document.sh verify <previous> <document>
#   scripts/trust-document.sh verify --first <document>
#       check <document> against the document before it, or the first one against its own
#       roots. Keys count once each, by the SHA-256 of their DER.
#   scripts/trust-document.sh show <document>
#       print the decoded document
#
# Exit 0 = done, 1 = refused, 2 = wrong usage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The reader's permanent caps.
MAX_FILE_BYTES=1048576
MAX_SIGNATURES=16
MAX_SIGNATURE_BYTES=4096

# Nine digits fit bash's arithmetic on every build and outrun any real version or threshold.
WHOLE_NUMBER='^[1-9][0-9]{0,8}$'
BASE64_TEXT='^[A-Za-z0-9+/]+={0,2}$'
NEWLINE=$'\n'
LINE_BREAKS=$'\r\n'

# Prints a JSON object's top-level fields, one line each, as name TAB kind TAB value, keeping
# a string's escapes as they are. A kind is string, array (followed by an item line per string
# in it and a not_text line per anything else) or other (a number, literal or object, as
# written). Exits 1 on anything else, and on a repeated name: the reader's JSON keeps the last
# one, which a reviewer of the first would never see.
JSON_FIELDS='
function skip_space() {
  while (at <= size && index(" \t\r\n", substr(text, at, 1)) > 0) at++
}
function read_string(start, c) {
  at++
  start = at
  while (at <= size) {
    c = substr(text, at, 1)
    if (c == "\"") {
      at++
      return substr(text, start, at - 1 - start)
    }
    if (c == "\n") exit 1
    at += (c == "\\") ? 2 : 1
  }
  exit 1
}
function skip_value(depth, c) {
  depth = 0
  do {
    skip_space()
    c = substr(text, at, 1)
    if (c == "") exit 1
    if (c == "\"") read_string()
    else if (c == "[" || c == "{") { depth++; at++ }
    else if (c == "]" || c == "}") { depth--; at++; if (depth < 0) exit 1 }
    else if (c == "," || c == ":") at++
    else while (at <= size && index(",:[]{}\" \t\r\n", substr(text, at, 1)) == 0) at++
  } while (depth > 0)
}
function read_array(name, c) {
  printf "%s\tarray\t\n", name
  at++
  skip_space()
  if (substr(text, at, 1) == "]") {
    at++
    return
  }
  while (1) {
    skip_space()
    if (substr(text, at, 1) == "\"") {
      printf "%s\titem\t%s\n", name, read_string()
    } else {
      skip_value()
      printf "%s\tnot_text\t\n", name
    }
    skip_space()
    c = substr(text, at, 1)
    at++
    if (c == "]") return
    if (c != ",") exit 1
  }
}
{ text = text $0 "\n" }
END {
  size = length(text)
  at = 1
  skip_space()
  if (substr(text, at, 1) != "{") exit 1
  at++
  skip_space()
  if (substr(text, at, 1) == "}") {
    at++
  } else {
    while (1) {
      skip_space()
      if (substr(text, at, 1) != "\"") exit 1
      name = read_string()
      if (name in seen) exit 1
      seen[name] = 1
      skip_space()
      if (substr(text, at, 1) != ":") exit 1
      at++
      skip_space()
      if (substr(text, at, 1) == "\"") {
        printf "%s\tstring\t%s\n", name, read_string()
      } else if (substr(text, at, 1) == "[") {
        read_array(name)
      } else {
        start = at
        skip_value()
        written = substr(text, start, at - start)
        gsub(/[\r\n]/, " ", written)
        printf "%s\tother\t%s\n", name, written
      }
      skip_space()
      separator = substr(text, at, 1)
      at++
      if (separator == "}") break
      if (separator != ",") exit 1
    }
  }
  skip_space()
  if (at <= size) exit 1
}
'

usage() {
  awk '/^# Usage:/ { show = 1 } /^set -euo/ { exit } show { sub(/^# ?/, ""); print }' "$0"
}

die() {
  echo "error: $*" >&2
  exit 1
}

read_fields() {
  LC_ALL=C awk "${JSON_FIELDS}" "$1"
}

# Writes the bytes of the base64 text $1 to the file $2. openssl skips what it cannot read, so
# the text is checked first, or a file the reader refuses could pass here. openssl limits a
# line it decodes, so the text is wrapped for it.
decode_base64() {
  [[ "$1" =~ ${BASE64_TEXT} ]] && (( ${#1} % 4 == 0 )) || return 1
  printf '%s' "$1" \
    | awk '{ for (i = 1; i <= length($0); i += 64) print substr($0, i, 64) }' \
    | openssl base64 -d -out "$2" 2>/dev/null || return 1
  [[ -s "$2" ]]
}

# Prints the file $1 as base64 on one line, however this openssl wraps or ends its lines.
encode_base64() {
  local text
  text="$(openssl base64 -in "$1")"
  printf '%s' "${text//[${LINE_BREAKS}]/}"
}

# Reads the document file $1, whose decoded bytes go to the file $2. Sets DOCUMENT_TEXT,
# SIGNATURE_TEXTS and SIGNATURE_FILES.
read_envelope() {
  local file="$1" decoded="$2" fields="${WORK}/envelope.fields" name kind value has_signatures=0 i
  [[ -f "${file}" ]] || die "no document at ${file}."
  (( $(wc -c < "${file}") <= MAX_FILE_BYTES )) || die "${file} is larger than ${MAX_FILE_BYTES} bytes."
  read_fields "${file}" > "${fields}" || die "${file} is not a JSON object."
  DOCUMENT_TEXT=""
  SIGNATURE_TEXTS=()
  SIGNATURE_FILES=()
  while IFS=$'\t' read -r name kind value; do
    case "${name}:${kind}" in
      document:string) DOCUMENT_TEXT="${value}" ;;
      signatures:array) has_signatures=1 ;;
      signatures:item) SIGNATURE_TEXTS+=("${value}") ;;
      signatures:not_text) die "${file}: a signature is not a string." ;;
    esac
  done < "${fields}"
  [[ -n "${DOCUMENT_TEXT}" && "${has_signatures}" == "1" ]] \
    || die "${file} does not hold a document and its signatures."
  (( ${#SIGNATURE_TEXTS[@]} <= MAX_SIGNATURES )) || die "${file} holds more than ${MAX_SIGNATURES} signatures."
  decode_base64 "${DOCUMENT_TEXT}" "${decoded}" || die "${file}: the document does not decode."
  for (( i = 0; i < ${#SIGNATURE_TEXTS[@]}; i++ )); do
    SIGNATURE_FILES+=("${WORK}/signature.${i}")
    decode_base64 "${SIGNATURE_TEXTS[i]}" "${SIGNATURE_FILES[i]}" || die "${file}: a signature does not decode."
    (( $(wc -c < "${SIGNATURE_FILES[i]}") <= MAX_SIGNATURE_BYTES )) \
      || die "${file}: a signature is larger than ${MAX_SIGNATURE_BYTES} bytes."
  done
}

# Reads the decoded document in the file $1. $2 names it in a refusal. Sets BODY_VERSION,
# BODY_THRESHOLD, BODY_ROOTS and BODY_RELEASES (a key's JSON text per line) and BODY_UNKNOWN (the
# names of the fields this script does not know).
read_body() {
  local decoded="$1" label="$2" fields="${WORK}/body.fields" name kind value format="" has_roots=0 has_releases=0
  read_fields "${decoded}" > "${fields}" || die "${label}: the document is not a JSON object."
  BODY_VERSION=""
  BODY_THRESHOLD=""
  BODY_ROOTS=""
  BODY_RELEASES=""
  BODY_UNKNOWN=""
  while IFS=$'\t' read -r name kind value; do
    case "${name}:${kind}" in
      format:other) format="${value}" ;;
      version:other) BODY_VERSION="${value}" ;;
      root_threshold:other) BODY_THRESHOLD="${value}" ;;
      root_keys:array) has_roots=1 ;;
      root_keys:item) BODY_ROOTS="${BODY_ROOTS:+${BODY_ROOTS}${NEWLINE}}${value}" ;;
      release_keys:array) has_releases=1 ;;
      release_keys:item) BODY_RELEASES="${BODY_RELEASES:+${BODY_RELEASES}${NEWLINE}}${value}" ;;
      root_keys:not_text|release_keys:not_text) die "${label}: a key in the document is not a string." ;;
      format:*|version:*|root_threshold:*|root_keys:*|release_keys:*) die "${label}: the document's ${name} has the wrong type." ;;
      *) BODY_UNKNOWN="${BODY_UNKNOWN} ${name}" ;;
    esac
  done < "${fields}"
  [[ "${format}" == "1" ]] || die "${label}: the document's format is not 1."
  [[ "${BODY_VERSION}" =~ ${WHOLE_NUMBER} ]] || die "${label}: the document's version is not a whole number from 1 up."
  [[ "${has_roots}" == "1" && -n "${BODY_ROOTS}" ]] || die "${label}: the document's root keys are empty."
  [[ "${BODY_THRESHOLD}" =~ ${WHOLE_NUMBER} ]] || die "${label}: the document's root threshold is not a whole number from 1 up."
  [[ "${has_releases}" == "1" ]] || die "${label}: the document's release keys are not a list."
}

# Prints the PEM a key's JSON text stands for.
pem_of_entry() {
  printf '%s' "$1" | awk '{ gsub(/\\n/, "\n"); gsub(/\\\//, "/"); gsub(/\\r/, ""); printf "%s", $0 }'
}

# `openssl dgst -sign` would quietly emit something else for another key type, and a PSS key
# prints a modulus too.
require_rsa_public() {
  local text
  text="$(openssl pkey -pubin -in "$1" -noout -text 2>/dev/null)" || {
    echo "error: $2 is not a PEM public key." >&2
    return 1
  }
  # OpenSSL 3's -pubin also loads a private key, so its answer cannot tell the two apart.
  if [[ "$(<"$1")" == *"PRIVATE KEY"* ]]; then
    echo "error: $2 is not a PEM public key." >&2
    return 1
  fi
  if [[ "${text}" != *Modulus* || "${text}" == *PSS* ]]; then
    echo "error: $2 is not an RSA key; a trust document's keys must be RSA." >&2
    return 1
  fi
}

# Prints the SHA-256 of the DER of the PEM public key in the file $1: one key in any layout has
# one answer. The script's own check, so nothing of it goes in a document.
key_hash() {
  local line
  openssl pkey -pubin -in "$1" -outform DER -out "${WORK}/key.der" 2>/dev/null || return 1
  line="$(openssl dgst -sha256 "${WORK}/key.der")" || return 1
  line="${line//[${LINE_BREAKS}]/}"
  printf '%s\n' "${line##* }"
}

# Prints the JSON text of the PEM public key in the file $1, its layout made uniform.
entry_of_pem() {
  openssl pkey -pubin -in "$1" -pubout -out "${WORK}/uniform.pem" 2>/dev/null || return 1
  awk 'BEGIN { ORS = "" } { gsub(/\r/, ""); print $0 "\\n" }' "${WORK}/uniform.pem"
}

# Prints the key list $1 with the PEM public key at the path $2 added. $3 names the list.
list_with() {
  local list="$1" path="$2" label="$3" hash line entry
  [[ -f "${path}" ]] || die "no key at ${path}."
  require_rsa_public "${path}" "${path}" || exit 1
  hash="$(key_hash "${path}")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    pem_of_entry "${line}" > "${WORK}/listed.pem"
    [[ "$(key_hash "${WORK}/listed.pem")" != "${hash}" ]] || die "${path} is already a ${label} key."
  done <<< "${list}"
  entry="$(entry_of_pem "${path}")"
  printf '%s\n' "${list:+${list}${NEWLINE}}${entry}"
}

# Prints the key list $1 without the PEM public key at the path $2. $3 names the list.
list_without() {
  local list="$1" path="$2" label="$3" hash line found=0 kept=""
  [[ -f "${path}" ]] || die "no key at ${path}."
  hash="$(key_hash "${path}")" || die "${path} is not a PEM public key."
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    pem_of_entry "${line}" > "${WORK}/listed.pem"
    if [[ "$(key_hash "${WORK}/listed.pem")" == "${hash}" ]]; then
      found=1
    else
      kept="${kept:+${kept}${NEWLINE}}${line}"
    fi
  done <<< "${list}"
  [[ "${found}" == "1" ]] || die "${path} is not a ${label} key of the previous document."
  printf '%s\n' "${kept}"
}

list_size() {
  local line count=0
  while IFS= read -r line; do
    [[ -z "${line}" ]] || count=$((count + 1))
  done <<< "$1"
  printf '%s\n' "${count}"
}

# Refuses a key list holding anything but loadable RSA public keys, and prints how many distinct
# keys it holds. $2 names the list.
distinct_keys() {
  local line hash seen=" " count=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    pem_of_entry "${line}" > "${WORK}/candidate.pem"
    require_rsa_public "${WORK}/candidate.pem" "a ${2} key" || exit 1
    hash="$(key_hash "${WORK}/candidate.pem")"
    case "${seen}" in
      *" ${hash} "*) ;;
      *)
        seen="${seen}${hash} "
        count=$((count + 1))
        ;;
    esac
  done <<< "$1"
  printf '%s\n' "${count}"
}

# Prints how many distinct keys of the list $1 verify some signature over the bytes in the file
# $2. The list has passed distinct_keys.
count_signing_keys() {
  local list="$1" decoded="$2" line hash seen=" " count=0 i
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    pem_of_entry "${line}" > "${WORK}/candidate.pem"
    hash="$(key_hash "${WORK}/candidate.pem")"
    case "${seen}" in
      *" ${hash} "*) continue ;;
    esac
    seen="${seen}${hash} "
    for (( i = 0; i < ${#SIGNATURE_FILES[@]}; i++ )); do
      if openssl dgst -sha256 -verify "${WORK}/candidate.pem" -signature "${SIGNATURE_FILES[i]}" "${decoded}" >/dev/null 2>&1; then
        count=$((count + 1))
        break
      fi
    done
  done <<< "${list}"
  printf '%s\n' "${count}"
}

# Writes the document file $1 from the base64 text $2 and the signature texts after it. Base64 is
# unwrapped and the shape fixed, so a diff of a document file shows what signed it.
write_document_file() {
  local target="$1" document="$2" list="" signature
  shift 2
  for signature in ${1+"$@"}; do
    list="${list:+${list}, }\"${signature}\""
  done
  PENDING="${target}.tmp"
  printf '{"document": "%s", "signatures": [%s]}\n' "${document}" "${list}" > "${PENDING}"
  mv "${PENDING}" "${target}"
}

# Prints the key list $1 as the inside of a JSON array.
json_items() {
  local line items=""
  while IFS= read -r line; do
    [[ -z "${line}" ]] || items="${items:+${items}, }\"${line}\""
  done <<< "$1"
  printf '%s' "${items}"
}

build_document() {
  local first=0 previous="" threshold="" out="" kept_threshold=1 version=1 roots="" releases=""
  local add_roots="" drop_roots="" add_releases="" drop_releases="" path
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --first)
        first=1
        shift
        ;;
      --add-root|--drop-root|--add-release|--drop-release|--threshold|--out)
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }
        case "$1" in
          --add-root) add_roots="${add_roots}${2}${NEWLINE}" ;;
          --drop-root) drop_roots="${drop_roots}${2}${NEWLINE}" ;;
          --add-release) add_releases="${add_releases}${2}${NEWLINE}" ;;
          --drop-release) drop_releases="${drop_releases}${2}${NEWLINE}" ;;
          --threshold) threshold="$2" ;;
          --out) out="$2" ;;
        esac
        shift 2
        ;;
      -*)
        usage >&2
        exit 2
        ;;
      *)
        [[ -z "${previous}" ]] || { usage >&2; exit 2; }
        previous="$1"
        shift
        ;;
    esac
  done
  if [[ "${first}" == "1" ]]; then
    [[ -z "${previous}" && -z "${drop_roots}${drop_releases}" ]] || { usage >&2; exit 2; }
    out="${out:-${REPO_ROOT}/trust}"
  else
    [[ -n "${previous}" ]] || { usage >&2; exit 2; }
    read_envelope "${previous}" "${WORK}/previous.decoded"
    read_body "${WORK}/previous.decoded" "${previous}"
    [[ -z "${BODY_UNKNOWN}" ]] || echo "warning: the new document leaves out${BODY_UNKNOWN}, which this script does not know." >&2
    version=$((BODY_VERSION + 1))
    kept_threshold="${BODY_THRESHOLD}"
    roots="${BODY_ROOTS}"
    releases="${BODY_RELEASES}"
    out="${out:-$(dirname "${previous}")}"
  fi
  while IFS= read -r path; do
    [[ -z "${path}" ]] || roots="$(list_without "${roots}" "${path}" root)"
  done <<< "${drop_roots}"
  while IFS= read -r path; do
    [[ -z "${path}" ]] || releases="$(list_without "${releases}" "${path}" release)"
  done <<< "${drop_releases}"
  while IFS= read -r path; do
    [[ -z "${path}" ]] || roots="$(list_with "${roots}" "${path}" root)"
  done <<< "${add_roots}"
  while IFS= read -r path; do
    [[ -z "${path}" ]] || releases="$(list_with "${releases}" "${path}" release)"
  done <<< "${add_releases}"

  local root_count
  root_count="$(list_size "${roots}")"
  (( root_count >= 1 )) || die "a document needs at least one root key."
  threshold="${threshold:-${kept_threshold}}"
  [[ "${threshold}" =~ ${WHOLE_NUMBER} ]] && (( threshold <= root_count )) \
    || die "the threshold ${threshold} is not between 1 and the ${root_count} root keys."

  local target="${out}/trust-${version}.json"
  # A document's content never changes once made, so an existing one is never replaced here.
  [[ ! -e "${target}" ]] || die "${target} already exists."
  [[ -d "${out}" ]] || die "no folder at ${out}."
  printf '{"format": 1, "version": %d, "root_keys": [%s], "root_threshold": %d, "release_keys": [%s]}\n' \
    "${version}" "$(json_items "${roots}")" "${threshold}" "$(json_items "${releases}")" > "${WORK}/new.decoded"
  write_document_file "${target}" "$(encode_base64 "${WORK}/new.decoded")"
  [[ -n "${releases}" ]] || echo "warning: this document lists no release key, which stops all updates." >&2
  echo "Wrote ${target}. Sign it with a threshold of the previous roots and of its own, then verify it."
}

sign_document() {
  [[ $# -eq 2 ]] || { usage >&2; exit 2; }
  local file="$1" key="$2" signature="${WORK}/new.signature" text i
  [[ -f "${key}" ]] || die "no key at ${key}."
  read_envelope "${file}" "${WORK}/document.decoded"
  (( ${#SIGNATURE_TEXTS[@]} < MAX_SIGNATURES )) || die "${file} already holds ${MAX_SIGNATURES} signatures."
  # This is the one read of the private key: a passphrase piped through stdin is gone after it,
  # so a second openssl call on the key would fail. An encrypted PEM does not say its key's type
  # before the passphrase opens it, so this same call refuses a non-RSA key: only an RSA key takes
  # this padding option, and a PSS key takes only PSS, so openssl stops before it signs. openssl
  # reads the passphrase line whether or not the key needs it, so even a plain key fails on an
  # empty pipe.
  if [[ -t 0 ]]; then
    openssl dgst -sha256 -sign "${key}" -sigopt rsa_padding_mode:pkcs1 -out "${signature}" "${WORK}/document.decoded" \
      || die "could not sign with ${key}: is it an RSA key, with the right passphrase? A trust document's keys must be RSA."
  else
    openssl dgst -sha256 -sign "${key}" -passin stdin -sigopt rsa_padding_mode:pkcs1 -out "${signature}" "${WORK}/document.decoded" \
      || die "could not sign with ${key}: is it an RSA key, with the right passphrase? A trust document's keys must be RSA."
  fi
  text="$(encode_base64 "${signature}")"
  for (( i = 0; i < ${#SIGNATURE_TEXTS[@]}; i++ )); do
    [[ "${SIGNATURE_TEXTS[i]}" != "${text}" ]] || die "${key} has already signed ${file}."
  done
  write_document_file "${file}" "${DOCUMENT_TEXT}" ${SIGNATURE_TEXTS[@]+"${SIGNATURE_TEXTS[@]}"} "${text}"
  echo "Signed ${file}: it holds $(( ${#SIGNATURE_TEXTS[@]} + 1 )) signatures. Check them with verify."
}

verify_document() {
  local previous="" file=""
  case "$#:${1:-}" in
    2:--first) file="$2" ;;
    2:-*) usage >&2; exit 2 ;;
    2:*)
      previous="$1"
      file="$2"
      ;;
    *) usage >&2; exit 2 ;;
  esac

  local previous_version=0 previous_roots="" previous_threshold=0 previous_signed=0
  if [[ -n "${previous}" ]]; then
    read_envelope "${previous}" "${WORK}/previous.decoded"
    read_body "${WORK}/previous.decoded" "${previous}"
    previous_version="${BODY_VERSION}"
    previous_roots="${BODY_ROOTS}"
    previous_threshold="${BODY_THRESHOLD}"
    distinct_keys "${previous_roots}" root > /dev/null
  fi

  read_envelope "${file}" "${WORK}/document.decoded"
  # The reader reads nothing inside a document before the previous roots vouch for it.
  if [[ -n "${previous}" ]]; then
    previous_signed="$(count_signing_keys "${previous_roots}" "${WORK}/document.decoded")"
    (( previous_signed >= previous_threshold )) \
      || die "${file}: ${previous_signed} of the previous roots signed it, and it needs ${previous_threshold}."
  fi

  read_body "${WORK}/document.decoded" "${file}"
  if [[ -n "${previous}" ]] && (( BODY_VERSION != previous_version + 1 )); then
    die "${file}: its version is ${BODY_VERSION}, and it must be $((previous_version + 1))."
  fi
  # A file named 7 holding 8 stops every client at 6 for good.
  local name
  name="$(basename "${file}")"
  if [[ "${name}" =~ ^trust-[0-9]+\.json$ && "${name}" != "trust-${BODY_VERSION}.json" ]]; then
    die "${file}: the file holds version ${BODY_VERSION}."
  fi
  local root_count release_count own_signed
  root_count="$(distinct_keys "${BODY_ROOTS}" root)"
  (( BODY_THRESHOLD <= root_count )) \
    || die "${file}: the root threshold ${BODY_THRESHOLD} is above its ${root_count} distinct root keys."
  release_count="$(distinct_keys "${BODY_RELEASES}" release)"
  own_signed="$(count_signing_keys "${BODY_ROOTS}" "${WORK}/document.decoded")"
  (( own_signed >= BODY_THRESHOLD )) \
    || die "${file}: ${own_signed} of its own roots signed it, and it needs ${BODY_THRESHOLD}."

  echo "${file}: version ${BODY_VERSION} holds."
  if [[ -n "${previous}" ]]; then
    echo "  previous roots: ${previous_signed} signed, ${previous_threshold} needed"
  fi
  echo "  its own roots: ${own_signed} of ${root_count} signed, ${BODY_THRESHOLD} needed"
  if (( release_count == 0 )); then
    echo "  release keys: none, which stops all updates"
  else
    echo "  release keys: ${release_count}"
  fi
}

show_document() {
  [[ $# -eq 1 ]] || { usage >&2; exit 2; }
  read_envelope "$1" "${WORK}/document.decoded"
  cat "${WORK}/document.decoded"
}

case "${1:-}" in
  build|sign|verify|show) ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required." >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/trust-document.XXXXXX")"
PENDING=""
trap 'rm -rf "${WORK}"; rm -f "${PENDING}"' EXIT

COMMAND="$1"
shift
case "${COMMAND}" in
  build) build_document "$@" ;;
  sign) sign_document "$@" ;;
  verify) verify_document "$@" ;;
  show) show_document "$@" ;;
esac
