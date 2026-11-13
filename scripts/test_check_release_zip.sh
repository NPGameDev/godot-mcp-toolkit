#!/usr/bin/env bash
# scripts/test_check_release_zip.sh
# Tests scripts/check-release-zip.mjs with no network, no Godot and no change to the
# repo. A fixture repository is made at run time and tagged; the zips are written by a
# small zip writer kept in this file, so each refused row breaks one rule and nothing
# else, and its stderr is compared whole: the one reason, and no other beside it.
#   - zips that pass: the release build's own, and the writer's with and without folder
#     entries, with MS-DOS attributes or Unix modes, against a tag, a commit id and a
#     tag with a committed list;
#   - one refused row for each rule the check's header names;
#   - the usage and setup errors.
#
# The row that runs the real build needs zip; it says "skip" without it, and
# CHECK_RELEASE_ZIP_REQUIRE_ALL=1 turns that skip into a failure.
#
# Usage: bash scripts/test_check_release_zip.sh   (from anywhere)
# Exit 0 = all passed, 1 = a check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release_files.sh
source "${REPO_ROOT}/scripts/lib/release_files.sh"

CHECKER="${REPO_ROOT}/scripts/check-release-zip.mjs"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-check-release-zip.XXXXXX")" && pwd)"
trap 'rm -rf "${WORK}"' EXIT

REPO="${WORK}/repo"
STAGE="${WORK}/stage"
ZIPS="${WORK}/zips"
ADDON="addons/godot_mcp_toolkit"
TAG="v1.2.0"

PASSED=0
FAILED=0
SKIPPED=0

# Compares a row's result with the one expected, and shows both when they differ.
expect() {
  local label="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    PASSED=$((PASSED + 1))
    echo "  ok    ${label}"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${label}"
    echo "        expected: ${expected}"
    echo "        actual:   ${actual}"
  fi
}

skip() {
  if [[ "${CHECK_RELEASE_ZIP_REQUIRE_ALL:-0}" == "1" ]]; then
    FAILED=$((FAILED + 1))
    echo "  FAIL  ${1} (CHECK_RELEASE_ZIP_REQUIRE_ALL is set)"
  else
    SKIPPED=$((SKIPPED + 1))
    echo "  skip  ${1}"
  fi
}

# Runs the check from the fixture repository's root, as a release does from the real
# one, and keeps its stdout, stderr and exit status. The zip is named by a relative
# path so the name the check prints is the same on every shell.
run_check() {
  STDOUT="$(cd "${REPO}" && node "${CHECKER}" "$@" 2> "${WORK}/stderr")" && STATUS=0 || STATUS=$?
  STDERR="$(tr -d '\r' < "${WORK}/stderr")"
}

# A row that must pass: exit 0, the one OK line on stdout, a silent stderr.
passes() {
  local label="$1" zip="$2" tag="${3:-${TAG}}"
  run_check "${zip}" "${tag}"
  expect "${label}" "${STATUS}|${STDOUT}|${STDERR}" "0|OK ${zip}|"
}

# A row that must be refused for one reason only: exit 1, a silent stdout, and a stderr
# that is that reason's line.
refused() {
  local label="$1" zip="$2" reason="$3" tag="${4:-${TAG}}"
  run_check "../zips/${zip}" "${tag}"
  expect "${label}" "${STATUS}|${STDOUT}|${STDERR}" "1||refused: ${reason}"
}

# A row whose break cannot be made without a second one: exit 1, a silent stdout, and
# the reason among the lines.
refused_among() {
  local label="$1" zip="$2" reason="$3" named=no
  run_check "../zips/${zip}" "${TAG}"
  [[ $'\n'"${STDERR}"$'\n' == *$'\n'"refused: ${reason}"$'\n'* ]] && named=yes
  expect "${label}" "${STATUS}|${STDOUT}|${named}" "1||yes"
}

# A usage or setup error: exit 2, a silent stdout, and the message on stderr.
setup_error() {
  local label="$1" message="$2" named=no
  shift 2
  run_check "$@"
  [[ "${STDERR}" == *"${message}"* ]] && named=yes
  expect "${label}" "${STATUS}|${STDOUT}|${named}" "2||yes"
}

fixture_git() {
  git -C "${REPO}" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c tag.gpgsign=false -c core.autocrlf=false -c core.ignorecase=false "$@"
}

# Tags a commit whose tree is the release's plus one path, without touching the working
# tree: a disk that folds case cannot hold two spellings of a name, and Windows cannot
# hold a symlink without a privilege.
tag_with_added_path() {
  local tag="$1" mode="$2" content="$3" path="$4" id
  id="$(printf '%s' "${content}" | fixture_git hash-object -w --stdin)"
  fixture_git read-tree "${TAG}"
  fixture_git update-index --add --cacheinfo "${mode},${id},${ADDON}/${path}"
  fixture_git commit -q -m "${tag}"
  fixture_git tag "${tag}"
}

echo "── the fixture ──"
# The shapes the real addon has, in a repository the real build script runs in: a
# dotfile, an empty file, nested folders, a file long enough to deflate, bytes that are
# not text, and a file outside the addon that no zip may hold.
mkdir -p "${REPO}/scripts/lib" "${REPO}/${ADDON}/CompanionSkills/references" \
  "${REPO}/${ADDON}/nested/deep" "${REPO}/${ADDON}/versioning" "${ZIPS}"
cp "${REPO_ROOT}/scripts/build-plugin-release.sh" "${REPO}/scripts/"
cp "${REPO_ROOT}/scripts/lib/release_files.sh" "${REPO_ROOT}/scripts/lib/compatible_server.sh" "${REPO}/scripts/lib/"
git init -q "${REPO}"
fixture_git commit -q --allow-empty -m "before the addon"
fixture_git tag v-no-addon
printf 'abc' > "${REPO}/${ADDON}/.mcp.json.template"
printf '' > "${REPO}/${ADDON}/CompanionSkills/.gdignore"
printf 'hello\n' > "${REPO}/${ADDON}/CompanionSkills/references/example.gd"
for line in $(seq 1 200); do
  printf 'line %s of a file long enough to deflate\n' "${line}"
done > "${REPO}/${ADDON}/nested/deep/data.txt"
printf '\000\001\r\n\377' > "${REPO}/${ADDON}/nested/bytes.bin"
printf '[plugin]\nversion="1.2.0"\n' > "${REPO}/${ADDON}/plugin.cfg"
printf 'const GODOT_MIN_VERSION := "4.9"\nconst COMPATIBLE_SERVER_VERSION := "9.8.7"\n' > "${REPO}/${ADDON}/versioning/mcp_version_utils.gd"
printf 'uid://fixture\n' > "${REPO}/${ADDON}/versioning/mcp_version_utils.gd.uid"
printf 'not part of the addon\n' > "${REPO}/README.md"
fixture_git add addons README.md
fixture_git commit -q -m "the release"
fixture_git tag -a -m "the release" "${TAG}"
RELEASE_COMMIT="$(fixture_git rev-parse "${TAG}^{commit}")"

tag_with_added_path v-case 100644 'upper' nested/deep/DATA.txt
tag_with_added_path v-symlink 120000 'plugin.cfg' link
tag_with_added_path v-committed-list 100644 'a stale list' release_files.sha256
fixture_git read-tree "${TAG}"

# The tree the build zips: the addon and the list of its files.
mkdir -p "${STAGE}/addons"
cp -R "${REPO}/${ADDON}" "${STAGE}/${ADDON}"
rf_write_list "${STAGE}/${ADDON}"

# Writes every case's zip from the staged tree. Each zip starts as the good one, with
# one field, entry or byte range changed.
cat > "${WORK}/write-zips.mjs" <<'WRITER'
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { deflateRawSync } from "node:zlib";

const [stage, out] = process.argv.slice(2);
const ADDON = "addons/godot_mcp_toolkit";
const LIST = `${ADDON}/release_files.sha256`;
const NONE = Buffer.alloc(0);
const UNIX = 3;
const ZIP64_EXTRA = Buffer.from([1, 0, 0, 0]);

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// An entry as the build writes it: deflated when that is smaller, made on Windows.
function file(name, data, changes = {}) {
  const deflated = deflateRawSync(data);
  const method = deflated.length < data.length ? 8 : 0;
  return {
    name, data, method, packed: method === 8 ? deflated : data, crc: crc32(data), size: data.length,
    flags: 0, time: 0x6000, date: 0x5b6d, versionNeeded: 20, host: 0, attributes: 0x20,
    extra: NONE, localExtra: NONE, comment: NONE, disk: 0, local: {}, ...changes,
  };
}

function folder(name, changes = {}) {
  return { ...file(name, NONE), attributes: 0x10, ...changes };
}

function walk(root, path) {
  return readdirSync(join(root, path), { withFileTypes: true }).flatMap((found) => {
    const name = `${path}/${found.name}`;
    return found.isDirectory() ? walk(root, name) : [file(name, readFileSync(join(root, name)))];
  });
}

function byName(a, b) {
  return Buffer.compare(Buffer.from(a.name), Buffer.from(b.name));
}

function withFolders(entries, changes = {}) {
  const names = new Set();
  for (const entry of entries) {
    for (let slash = entry.name.indexOf("/"); slash >= 0; slash = entry.name.indexOf("/", slash + 1)) {
      names.add(entry.name.slice(0, slash + 1));
    }
  }
  return [...[...names].map((name) => folder(name, changes)), ...entries].sort(byName);
}

function listOf(entries) {
  return Buffer.from(
    entries
      .filter((entry) => entry.name !== LIST)
      .map((entry) => [entry.name.slice(ADDON.length + 1), entry.data])
      .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
      .map(([name, data]) => `${createHash("sha256").update(data).digest("hex")}  ${name}\n`)
      .join(""),
  );
}

function localRecord(entry) {
  const header = { ...entry, compressedSize: entry.compressedSize ?? entry.packed.length, ...entry.local };
  const name = Buffer.from(header.name);
  const fixed = Buffer.alloc(30);
  fixed.writeUInt32LE(header.signature ?? 0x04034b50, 0);
  fixed.writeUInt16LE(header.versionNeeded, 4);
  fixed.writeUInt16LE(header.flags, 6);
  fixed.writeUInt16LE(header.method, 8);
  fixed.writeUInt16LE(header.time, 10);
  fixed.writeUInt16LE(header.date, 12);
  fixed.writeUInt32LE(header.crc, 14);
  fixed.writeUInt32LE(header.compressedSize, 18);
  fixed.writeUInt32LE(header.size, 22);
  fixed.writeUInt16LE(name.length, 26);
  fixed.writeUInt16LE(entry.localExtra.length, 28);
  return Buffer.concat([fixed, name, entry.localExtra, entry.packed]);
}

function centralRecord(entry, offset) {
  const name = Buffer.from(entry.name);
  const fixed = Buffer.alloc(46);
  fixed.writeUInt32LE(0x02014b50, 0);
  fixed.writeUInt16LE((entry.host << 8) | 30, 4);
  fixed.writeUInt16LE(entry.versionNeeded, 6);
  fixed.writeUInt16LE(entry.flags, 8);
  fixed.writeUInt16LE(entry.method, 10);
  fixed.writeUInt16LE(entry.time, 12);
  fixed.writeUInt16LE(entry.date, 14);
  fixed.writeUInt32LE(entry.crc, 16);
  fixed.writeUInt32LE(entry.compressedSize ?? entry.packed.length, 20);
  fixed.writeUInt32LE(entry.size, 24);
  fixed.writeUInt16LE(name.length, 28);
  fixed.writeUInt16LE(entry.extra.length, 30);
  fixed.writeUInt16LE(entry.comment.length, 32);
  fixed.writeUInt16LE(entry.disk, 34);
  fixed.writeUInt32LE(entry.attributes, 38);
  fixed.writeUInt32LE(offset, 42);
  return Buffer.concat([fixed, name, entry.extra, entry.comment]);
}

// layout: prefix, afterFirstEntry, beforeDirectory, beforeEnd, comment and suffix are
// bytes put at those places; end overrides the end record's fields. An entry with
// sharesRecordOf has no record of its own and points at that entry's.
function write(zipName, entries, layout = {}) {
  const records = [layout.prefix ?? NONE];
  const offsets = [];
  let at = records[0].length;
  entries.forEach((entry, index) => {
    if (entry.sharesRecordOf !== undefined) {
      offsets.push(offsets[entry.sharesRecordOf]);
      return;
    }
    offsets.push(at);
    records.push(localRecord(entry));
    if (index === 0) {
      records.push(layout.afterFirstEntry ?? NONE);
    }
    at = records.reduce((total, record) => total + record.length, 0);
  });
  records.push(layout.beforeDirectory ?? NONE);
  const directoryOffset = records.reduce((total, record) => total + record.length, 0);
  const directory = Buffer.concat(entries.map((entry, index) => centralRecord(entry, offsets[index])));
  const comment = layout.comment ?? NONE;
  const end = {
    disk: 0, directoryDisk: 0, entriesOnDisk: entries.length, entries: entries.length,
    directorySize: directory.length, directoryOffset, ...layout.end,
  };
  const fixed = Buffer.alloc(22);
  fixed.writeUInt32LE(0x06054b50, 0);
  fixed.writeUInt16LE(end.disk, 4);
  fixed.writeUInt16LE(end.directoryDisk, 6);
  fixed.writeUInt16LE(end.entriesOnDisk, 8);
  fixed.writeUInt16LE(end.entries, 10);
  fixed.writeUInt32LE(end.directorySize, 12);
  fixed.writeUInt32LE(end.directoryOffset, 16);
  fixed.writeUInt16LE(comment.length, 20);
  writeFileSync(
    join(out, `${zipName}.zip`),
    Buffer.concat([...records, directory, layout.beforeEnd ?? NONE, fixed, comment, layout.suffix ?? NONE]),
  );
}

const files = walk(stage, ADDON).sort(byName);
const good = withFolders(files);
const path = (name) => `${ADDON}/${name}`;
const without = (name) => good.filter((entry) => entry.name !== path(name));
const changed = (name, changes) =>
  good.map((entry) => (entry.name === path(name) ? { ...entry, ...changes } : entry));
const rewritten = (name, data) =>
  good.map((entry) => (entry.name === path(name) ? file(entry.name, Buffer.from(data)) : entry));
const plugin = good.find((entry) => entry.name === path("plugin.cfg"));
const deflatedFile = good.find((entry) => entry.name === path("nested/deep/data.txt"));
if (plugin.method !== 0 || deflatedFile.method !== 8) {
  throw new Error("the fixture must hold plugin.cfg stored and nested/deep/data.txt deflated");
}

write("good", good);
write("good-no-folders", files);
write(
  "good-unix",
  withFolders(files, { host: UNIX, attributes: ((0o040755 << 16) | 0x10) >>> 0 }).map((entry) =>
    entry.name.endsWith("/") ? entry : { ...entry, host: UNIX, attributes: (0o100644 << 16) >>> 0 },
  ),
);

// The entry list.
write("missing", without("nested/deep/data.txt"));
write("no-list", without("release_files.sha256"));
write("extra", [...good, file(path("stray.gd"), Buffer.from("x"))]);
write("outside", [...good, file("addons/other.txt", Buffer.from("x"))]);
write("duplicate", [...good, plugin]);
const upper = file(path("nested/deep/DATA.txt"), Buffer.from("upper"));
write(
  "case",
  [...good, upper].map((entry) =>
    entry.name === LIST ? file(LIST, listOf([...files, upper])) : entry,
  ),
);

// The bytes.
write("tampered", rewritten("plugin.cfg", '[plugin]\nversion="6.6.6"\n'));
write("crlf", rewritten("CompanionSkills/references/example.gd", "hello\r\n"));
write("stale-list", rewritten("release_files.sha256", "0".repeat(64) + "  plugin.cfg\n"));
write("bad-crc", changed("plugin.cfg", { crc: (plugin.crc ^ 1) >>> 0 }));
write("wrong-size", changed("plugin.cfg", { size: plugin.size + 1 }));
write(
  "deflate-trailing",
  changed("nested/deep/data.txt", { packed: Buffer.concat([deflatedFile.packed, Buffer.from("junk")]) }),
);
write("broken-deflate", changed("nested/deep/data.txt", { packed: Buffer.alloc(40, 0xff) }));

// Regular files, and folders of the tag's files.
write("symlink", changed("plugin.cfg", { host: UNIX, attributes: (0o120777 << 16) >>> 0 }));
write("folder-bit", changed("plugin.cfg", { attributes: 0x10 }));
write("folder-symlink", changed("nested/", { host: UNIX, attributes: (0o120777 << 16) >>> 0 }));
write("folder-unknown", [...good, folder(path("empty/"))]);
write("folder-data", changed("nested/", { packed: Buffer.from("x"), size: 1, crc: crc32(Buffer.from("x")) }));

// Comments, ZIP64, disks, encryption, methods.
write("comment", good, { comment: Buffer.from("hi") });
write("entry-comment", changed("plugin.cfg", { comment: Buffer.from("hi") }));
const zip64End = Buffer.alloc(56);
zip64End.writeUInt32LE(0x06064b50, 0);
const zip64Locator = Buffer.alloc(20);
zip64Locator.writeUInt32LE(0x07064b50, 0);
write("zip64-locator", good, { beforeEnd: Buffer.concat([zip64End, zip64Locator]) });
write("zip64-count", good, { end: { entries: 0xffff, entriesOnDisk: 0xffff } });
write("zip64-extra", changed("plugin.cfg", { extra: ZIP64_EXTRA }));
write("zip64-local-extra", changed("plugin.cfg", { localExtra: ZIP64_EXTRA }));
write("zip64-size", changed("plugin.cfg", { size: 0xffffffff }));
write("second-disk", good, { end: { disk: 1 } });
write("encrypted", changed("plugin.cfg", { flags: 0x0001 }));
write("method", changed("plugin.cfg", { method: 12 }));

// The local headers.
write("data-descriptor", changed("plugin.cfg", { flags: 0x0008 }));
write("no-local", changed("plugin.cfg", { local: { signature: 0x04034b51 } }));
write("data-past-directory", changed("plugin.cfg", { compressedSize: 0x00ffffff }));
const localChanges = {
  "name": { name: path("plugin.cfX") },
  "version-needed": { versionNeeded: 21 },
  "flags": { flags: 0x0800 },
  "method": { method: 8 },
  "time": { time: 0x6001 },
  "date": { date: 0x5b6e },
  "crc": { crc: (plugin.crc ^ 1) >>> 0 },
  "compressed-size": { compressedSize: plugin.packed.length + 1 },
  "size": { size: plugin.size + 1 },
};
for (const [field, local] of Object.entries(localChanges)) {
  write(`local-${field}`, changed("plugin.cfg", { local }));
}

// Every byte accounted for.
write("prefix", good, { prefix: Buffer.from("MZ junk") });
write("hidden-record", good, { afterFirstEntry: localRecord(file("evil", Buffer.from("x"))) });
write("gap-before-directory", good, { beforeDirectory: Buffer.from("gap") });
write("gap-before-end", good, { beforeEnd: Buffer.from("junk") });
write("suffix", good, { suffix: Buffer.from("xy") });
write("overlap", [...good, { ...plugin, sharesRecordOf: good.indexOf(plugin) }]);
write("uncounted", good, { end: { entries: good.length - 1, entriesOnDisk: good.length - 1 } });
write("overcounted", good, { end: { entries: good.length + 1, entriesOnDisk: good.length + 1 } });
writeFileSync(join(out, "not-a-zip.zip"), "not a zip");
writeFileSync(join(out, "empty.zip"), NONE);
console.log(good.length);
WRITER
ENTRY_COUNT="$(node "${WORK}/write-zips.mjs" "${STAGE}" "${ZIPS}" | tr -d '\r')"
expect "the writer's good zip holds the 8 files, the list and 7 folders" "${ENTRY_COUNT}" "16"

echo "── zips that pass ──"
passes "a zip with folder entries" ../zips/good.zip
passes "a zip with no folder entries" ../zips/good-no-folders.zip
passes "a zip whose entries carry Unix modes" ../zips/good-unix.zip
passes "the tag named by its commit id" ../zips/good.zip "${RELEASE_COMMIT}"
passes "a list committed at the tag gives way to the build's" ../zips/good.zip v-committed-list
if command -v zip >/dev/null 2>&1; then
  if bash "${REPO}/scripts/build-plugin-release.sh" >/dev/null 2>&1; then
    passes "the release build's own zip" dist-plugin/godot-mcp-toolkit-1.2.0.zip
  else
    expect "the release build runs on the fixture" "failed" "built"
  fi
else
  skip "the release build's own zip needs zip"
fi

echo "── the entry list ──"
refused "a file of the tag left out" missing.zip "${ADDON}/nested/deep/data.txt is missing"
refused "no release_files.sha256" no-list.zip "${ADDON}/release_files.sha256 is missing"
refused "a file the tag does not have" extra.zip "${ADDON}/stray.gd is not in the addon at the tag"
refused "a file outside the addon folder" outside.zip "addons/other.txt is not in the addon at the tag"
refused "a name listed twice" duplicate.zip "${ADDON}/plugin.cfg is listed 2 times"
refused "two names that differ only by case, both at the tag" case.zip \
  "names that differ only by case: ${ADDON}/nested/deep/DATA.txt, ${ADDON}/nested/deep/data.txt" v-case
refused "a symlink at the tag" good.zip \
  "${ADDON}/link is not a regular file at the tag (mode 120000), so no zip can match it" v-symlink

echo "── the bytes ──"
refused "a file that differs from its blob" tampered.zip "${ADDON}/plugin.cfg differs from the blob at the tag"
refused "a file from a CRLF checkout" crlf.zip "${ADDON}/CompanionSkills/references/example.gd differs from the blob at the tag"
refused "a list that is not the tag's files" stale-list.zip "${ADDON}/release_files.sha256 is not the list of the tag's files"
refused "a CRC-32 that is not the bytes'" bad-crc.zip "${ADDON}/plugin.cfg has a CRC-32 that does not match its bytes"
refused "a stated size that is not the bytes'" wrong-size.zip "${ADDON}/plugin.cfg holds 25 bytes, and its header states 26"
refused "bytes after a deflate stream" deflate-trailing.zip "${ADDON}/nested/deep/data.txt holds 4 bytes after its deflate stream"
refused "a deflate stream that does not inflate" broken-deflate.zip "${ADDON}/nested/deep/data.txt does not inflate to the 8292 bytes its header states"

echo "── regular files, and folders of the tag's files ──"
refused "a symlink" symlink.zip "${ADDON}/plugin.cfg is not a regular file"
refused "a file marked as a folder" folder-bit.zip "${ADDON}/plugin.cfg is not a regular file"
refused "a folder name on a symlink" folder-symlink.zip "${ADDON}/nested/ is neither a regular file nor a folder"
refused "a folder that is no parent of a file of the tag" folder-unknown.zip "${ADDON}/empty/ is a folder that holds none of the tag's files"
refused "a folder entry with data" folder-data.zip "${ADDON}/nested/ is a folder entry that holds data"

echo "── comments, ZIP64, disks, encryption, methods ──"
refused "an archive comment" comment.zip "the archive has a comment"
refused "an entry comment" entry-comment.zip "${ADDON}/plugin.cfg carries a comment"
refused "a ZIP64 end record" zip64-locator.zip "the archive uses ZIP64"
refused "a ZIP64 entry count" zip64-count.zip "the archive uses ZIP64"
refused "a ZIP64 extra field in the central directory" zip64-extra.zip "${ADDON}/plugin.cfg uses ZIP64"
refused "a ZIP64 extra field in the local header" zip64-local-extra.zip "${ADDON}/plugin.cfg uses ZIP64"
refused "a ZIP64 size" zip64-size.zip "${ADDON}/plugin.cfg uses ZIP64"
refused "a second disk" second-disk.zip "the end record describes an archive split over several disks"
refused "an encrypted entry" encrypted.zip "${ADDON}/plugin.cfg is encrypted"
refused "a method that is neither stored nor deflate" method.zip "${ADDON}/plugin.cfg uses compression method 12, which is neither stored nor deflate"

echo "── the local headers ──"
local_differs() {
  refused "a local header with another $1" "local-$2.zip" "${ADDON}/plugin.cfg has a local header that differs from the central directory in: $1"
}
local_differs "name" name
local_differs "version needed" version-needed
local_differs "flags" flags
local_differs "method" method
local_differs "time" time
local_differs "date" date
local_differs "CRC-32" crc
local_differs "compressed size" compressed-size
local_differs "size" size
refused "sizes left to a data descriptor" data-descriptor.zip \
  "${ADDON}/plugin.cfg leaves its sizes to a data descriptor, so its local header cannot match the central directory"
refused "no local header at the offset" no-local.zip "${ADDON}/plugin.cfg has no local header where the central directory points"
refused "data longer than the archive" data-past-directory.zip "${ADDON}/plugin.cfg has data that runs past the start of the central directory"

echo "── every byte accounted for ──"
refused "bytes before the first entry" prefix.zip "7 bytes sit before the first entry"
refused "a record no central entry names, between two entries" hidden-record.zip "35 bytes sit between entries, before addons/godot_mcp_toolkit/"
refused "bytes between the last entry and the central directory" gap-before-directory.zip "3 bytes sit between the last entry and the central directory"
refused "bytes between the central directory and the end record" gap-before-end.zip "the central directory does not end where the end record starts"
refused "bytes after the end record" suffix.zip "2 bytes sit after the end record"
refused_among "two entries on one record" overlap.zip "${ADDON}/plugin.cfg overlaps the entry before it"
refused "a central entry the end record does not count" uncounted.zip "the central directory holds bytes after the last entry the end record counts"
refused "an end record that counts one entry too many" overcounted.zip "the central directory holds 16 entries, and the end record counts 17"
refused "a file that is not a zip" not-a-zip.zip "it has no end record, so it is not a zip archive"
refused "an empty file" empty.zip "it has no end record, so it is not a zip archive"

echo "── usage and setup errors ──"
setup_error "no argument" "usage: node scripts/check-release-zip.mjs <zip> <tag>"
setup_error "one argument" "usage:" ../zips/good.zip
setup_error "three arguments" "usage:" ../zips/good.zip "${TAG}" extra
setup_error "a tag that reads as an option" "usage:" ../zips/good.zip --all
setup_error "no file at the zip's path" "cannot read ../zips/absent.zip" ../zips/absent.zip "${TAG}"
setup_error "a tag the repository does not have" "no commit named 'v9.9.9'" ../zips/good.zip v9.9.9
setup_error "a commit with no addon" "holds no file under ${ADDON}" ../zips/good.zip v-no-addon
# The ceiling keeps git from finding a repository above the temp folder.
STDOUT="$(cd "${ZIPS}" && GIT_CEILING_DIRECTORIES="${WORK}" node "${CHECKER}" good.zip "${TAG}" 2> "${WORK}/stderr")" && STATUS=0 || STATUS=$?
expect "a folder that is in no repository" "${STATUS}|${STDOUT}" "2|"

echo ""
if [[ ${FAILED} -eq 0 ]]; then
  echo "PASS: ${PASSED} checks, ${SKIPPED} skipped"
  exit 0
fi
echo "FAIL: ${FAILED} of $((PASSED + FAILED)) checks failed, ${SKIPPED} skipped"
exit 1
