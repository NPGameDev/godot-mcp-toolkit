#!/usr/bin/env node
// Refuses a release zip unless it is exactly the addon at a tag: the files of
// addons/godot_mcp_toolkit there, byte for byte, plus the release's file list, and
// nothing else a zip reader could find.
//
// Usage: node scripts/check-release-zip.mjs <zip> <tag>
//
// Run it from the repository's root: it reads <tag> from the repository of the
// current folder. <tag> is any name git resolves to a commit.
//
// A zip passes when:
//   - its entries are the tag's files and release_files.sha256, each listed once, with
//     no two names differing only by case. A folder entry is allowed for a folder that
//     holds one of those files, and for nothing else;
//   - every file's bytes are the blob at the tag, and release_files.sha256 is the list
//     of those blobs, in the format scripts/lib/release_files.sh writes;
//   - every entry is a regular file or such a folder, stored or deflated, not
//     encrypted, with a local header that agrees with the central directory;
//   - it has no comment, no ZIP64 record and no second disk, and its entries, central
//     directory and end record fill the file: no byte before, between or after them.
//
// Zip readers disagree on an archive that breaks one of these: one takes the first of
// two entries with the same name and another the last, one trusts the local header
// and another the central directory. Comparing what a single tool extracts can
// therefore pass a zip that installs something else, so this reads the format itself
// and refuses whatever two readers could read differently.
//
// Prints "OK <zip>" on stdout when the zip passes, and nothing else there.
// Exit codes: 0 the zip passes; 1 it is refused, one reason per line on stderr;
// 2 a usage or setup error.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { inflateRawSync } from "node:zlib";

const ADDON_DIR = "addons/godot_mcp_toolkit";
const LIST_PATH = `${ADDON_DIR}/release_files.sha256`;
const REGULAR_GIT_MODES = ["100644", "100755"];
const GIT_OUTPUT_LIMIT = 2 ** 30;

const LOCAL_SIGNATURE = 0x04034b50;
const CENTRAL_SIGNATURE = 0x02014b50;
const END_SIGNATURE = 0x06054b50;
const ZIP64_LOCATOR_SIGNATURE = 0x07064b50;
const LOCAL_SIZE = 30;
const CENTRAL_SIZE = 46;
const END_SIZE = 22;
const ZIP64_LOCATOR_SIZE = 20;
const LONGEST_COMMENT = 0xffff;

// The values a ZIP64 archive leaves in a field whose real value sits in a ZIP64 record.
const ZIP64_PLACEHOLDER_16 = 0xffff;
const ZIP64_PLACEHOLDER_32 = 0xffffffff;
const ZIP64_EXTRA_ID = 0x0001;

// Bit 0 is the classic cipher, bit 6 strong encryption, bit 13 a masked central directory.
const ENCRYPTION_FLAGS = 0x0001 | 0x0040 | 0x2000;
const DATA_DESCRIPTOR_FLAG = 0x0008;
const METHOD_STORED = 0;
const METHOD_DEFLATE = 8;

// The external attributes hold an MS-DOS attribute byte and, in the high half, a Unix
// mode. A type of zero is a writer that recorded no Unix mode.
const DOS_DIRECTORY = 0x10;
const UNIX_TYPE_MASK = 0o170000;
const UNIX_REGULAR = 0o100000;
const UNIX_DIRECTORY = 0o040000;

// The fields a local header repeats from the central directory, at their offsets in
// each. The extra field is left out: writers put different timestamps and
// permissions in the two.
const SHARED_FIELDS = [
  { label: "version needed", local: 4, central: 6, bytes: 2 },
  { label: "flags", local: 6, central: 8, bytes: 2 },
  { label: "method", local: 8, central: 10, bytes: 2 },
  { label: "time", local: 10, central: 12, bytes: 2 },
  { label: "date", local: 12, central: 14, bytes: 2 },
  { label: "CRC-32", local: 14, central: 16, bytes: 4 },
  { label: "compressed size", local: 18, central: 20, bytes: 4 },
  { label: "size", local: 22, central: 24, bytes: 4 },
];

const CRC_TABLE = new Uint32Array(256).map((_, index) => {
  let remainder = index;
  for (let bit = 0; bit < 8; bit++) {
    remainder = remainder & 1 ? 0xedb88320 ^ (remainder >>> 1) : remainder >>> 1;
  }
  return remainder;
});

class SetupError extends Error {}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// Paths are held as latin1 strings, one character per byte, so a zip's name and git's
// path compare byte for byte whatever encoding they are in.
function pathOf(buffer, start, end) {
  return buffer.toString("latin1", start, end);
}

function readable(path) {
  return Buffer.from(path, "latin1").toString("utf8");
}

function git(args, input) {
  const result = spawnSync("git", args, { input, maxBuffer: GIT_OUTPUT_LIMIT });
  if (result.error) {
    throw new SetupError(`could not run git: ${result.error.message}`);
  }
  return result;
}

function resolveCommit(tag) {
  const resolved = git(["rev-parse", "--verify", "--quiet", `${tag}^{commit}`]);
  if (resolved.status !== 0) {
    throw new SetupError(`no commit named '${tag}' in the repository of the current folder`);
  }
  return resolved.stdout.toString().trim();
}

// Returns each blob's bytes, in the order asked.
function readBlobs(ids) {
  const batch = git(["cat-file", "--batch"], ids.map((id) => `${id}\n`).join(""));
  if (batch.status !== 0) {
    throw new SetupError(`git cat-file failed: ${batch.stderr.toString().trim()}`);
  }
  const blobs = [];
  let at = 0;
  for (const id of ids) {
    const headerEnd = batch.stdout.indexOf("\n", at);
    const [answeredId, type, size] = batch.stdout.toString("latin1", at, headerEnd).split(" ");
    if (headerEnd < 0 || answeredId !== id || type !== "blob") {
      throw new SetupError(`git cat-file returned no blob for ${id}`);
    }
    const start = headerEnd + 1;
    blobs.push(batch.stdout.subarray(start, start + Number(size)));
    at = start + Number(size) + 1;
  }
  return blobs;
}

// The list the build writes into the zip: one "<sha256>  <path>" line per file, paths
// relative to the addon folder and sorted by byte.
function fileList(files) {
  const lines = [];
  for (const [path, bytes] of files) {
    if (bytes !== null) {
      const relative = path.slice(ADDON_DIR.length + 1);
      lines.push([relative, createHash("sha256").update(bytes).digest("hex")]);
    }
  }
  lines.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return Buffer.from(lines.map(([path, hash]) => `${hash}  ${path}\n`).join(""), "latin1");
}

// Returns a map from each path the zip must hold to its bytes. A path the tag holds as
// something no zip entry can match (a symlink, a submodule) maps to null, with a reason.
function readExpectedFiles(commit, reasons) {
  const listed = git(["ls-tree", "-r", "-z", "--full-tree", commit, "--", ADDON_DIR]);
  if (listed.status !== 0) {
    throw new SetupError(`git ls-tree failed: ${listed.stderr.toString().trim()}`);
  }
  const expected = new Map();
  const regular = [];
  for (const record of pathOf(listed.stdout).split("\0")) {
    if (record === "") {
      continue;
    }
    const tab = record.indexOf("\t");
    const [mode, , id] = record.slice(0, tab).split(" ");
    const path = record.slice(tab + 1);
    if (path === LIST_PATH) {
      // The build writes the list over whatever is committed at its path.
      continue;
    }
    if (REGULAR_GIT_MODES.includes(mode)) {
      regular.push({ path, id });
    } else {
      expected.set(path, null);
      reasons.push(`${readable(path)} is not a regular file at the tag (mode ${mode}), so no zip can match it`);
    }
  }
  if (regular.length === 0) {
    throw new SetupError(`the commit holds no file under ${ADDON_DIR}`);
  }
  const blobs = readBlobs(regular.map((file) => file.id));
  regular.forEach((file, index) => expected.set(file.path, blobs[index]));
  expected.set(LIST_PATH, fileList(expected));
  return expected;
}

// Returns the end record, or null with a reason when the archive cannot be walked.
function readEndRecord(zip, reasons) {
  // Searched backwards from the end, as a reader of the central directory does.
  let at = zip.length - END_SIZE;
  const lowest = Math.max(0, at - LONGEST_COMMENT);
  while (at >= lowest && zip.readUInt32LE(at) !== END_SIGNATURE) {
    at--;
  }
  if (at < lowest) {
    reasons.push("it has no end record, so it is not a zip archive");
    return null;
  }
  const end = {
    at,
    disk: zip.readUInt16LE(at + 4),
    directoryDisk: zip.readUInt16LE(at + 6),
    entriesOnDisk: zip.readUInt16LE(at + 8),
    entries: zip.readUInt16LE(at + 10),
    directorySize: zip.readUInt32LE(at + 12),
    directoryOffset: zip.readUInt32LE(at + 16),
    commentLength: zip.readUInt16LE(at + 20),
  };
  const after = zip.length - (at + END_SIZE);
  if (end.commentLength !== 0) {
    reasons.push("the archive has a comment");
  } else if (after !== 0) {
    reasons.push(`${after} bytes sit after the end record`);
  }
  const hasZip64Locator =
    at >= ZIP64_LOCATOR_SIZE && zip.readUInt32LE(at - ZIP64_LOCATOR_SIZE) === ZIP64_LOCATOR_SIGNATURE;
  if (
    hasZip64Locator ||
    end.entries === ZIP64_PLACEHOLDER_16 ||
    end.directorySize === ZIP64_PLACEHOLDER_32 ||
    end.directoryOffset === ZIP64_PLACEHOLDER_32
  ) {
    reasons.push("the archive uses ZIP64");
    return null;
  }
  if (end.disk !== 0 || end.directoryDisk !== 0 || end.entriesOnDisk !== end.entries) {
    reasons.push("the end record describes an archive split over several disks");
    return null;
  }
  if (end.directoryOffset + end.directorySize !== at) {
    reasons.push("the central directory does not end where the end record starts");
    return null;
  }
  return end;
}

// Returns the central directory's entries, or null with a reason when it does not hold
// exactly the entries the end record counts.
function readCentralDirectory(zip, end, reasons) {
  const entries = [];
  let at = end.directoryOffset;
  for (let index = 0; index < end.entries; index++) {
    const fits = at + CENTRAL_SIZE <= end.at && zip.readUInt32LE(at) === CENTRAL_SIGNATURE;
    const nameEnd = fits ? at + CENTRAL_SIZE + zip.readUInt16LE(at + 28) : 0;
    const extraEnd = fits ? nameEnd + zip.readUInt16LE(at + 30) : 0;
    const next = fits ? extraEnd + zip.readUInt16LE(at + 32) : 0;
    if (!fits || next > end.at) {
      reasons.push(`the central directory holds ${index} entries, and the end record counts ${end.entries}`);
      return null;
    }
    entries.push({
      at,
      name: pathOf(zip, at + CENTRAL_SIZE, nameEnd),
      flags: zip.readUInt16LE(at + 8),
      method: zip.readUInt16LE(at + 10),
      crc: zip.readUInt32LE(at + 16),
      compressedSize: zip.readUInt32LE(at + 20),
      size: zip.readUInt32LE(at + 24),
      extra: zip.subarray(nameEnd, extraEnd),
      commentLength: next - extraEnd,
      disk: zip.readUInt16LE(at + 34),
      externalAttributes: zip.readUInt32LE(at + 38),
      localOffset: zip.readUInt32LE(at + 42),
    });
    at = next;
  }
  if (at !== end.at) {
    reasons.push("the central directory holds bytes after the last entry the end record counts");
    return null;
  }
  return entries;
}

function hasZip64Extra(extra) {
  for (let at = 0; at + 4 <= extra.length; at += 4 + extra.readUInt16LE(at + 2)) {
    if (extra.readUInt16LE(at) === ZIP64_EXTRA_ID) {
      return true;
    }
  }
  return false;
}

// Checks an entry's two headers against the rules and each other, and records where its
// data starts and its record ends. Both stay unset, with a reason, when it has no usable
// local record.
function checkHeaders(zip, entry, directoryOffset, refuse) {
  if (entry.flags & ENCRYPTION_FLAGS) {
    refuse("is encrypted");
  }
  if (entry.commentLength !== 0) {
    refuse("carries a comment");
  }
  if (entry.method !== METHOD_STORED && entry.method !== METHOD_DEFLATE) {
    refuse(`uses compression method ${entry.method}, which is neither stored nor deflate`);
  }
  if (entry.flags & DATA_DESCRIPTOR_FLAG) {
    refuse("leaves its sizes to a data descriptor, so its local header cannot match the central directory");
  }
  let zip64 =
    entry.compressedSize === ZIP64_PLACEHOLDER_32 ||
    entry.size === ZIP64_PLACEHOLDER_32 ||
    entry.localOffset === ZIP64_PLACEHOLDER_32 ||
    entry.disk === ZIP64_PLACEHOLDER_16 ||
    hasZip64Extra(entry.extra);

  const local = entry.localOffset;
  const hasLocal = local + LOCAL_SIZE <= directoryOffset && zip.readUInt32LE(local) === LOCAL_SIGNATURE;
  if (hasLocal) {
    const nameEnd = local + LOCAL_SIZE + zip.readUInt16LE(local + 26);
    const dataStart = nameEnd + zip.readUInt16LE(local + 28);
    zip64 = zip64 || hasZip64Extra(zip.subarray(nameEnd, dataStart));
    const differing = SHARED_FIELDS.filter(
      (field) =>
        zip.readUIntLE(local + field.local, field.bytes) !== zip.readUIntLE(entry.at + field.central, field.bytes),
    ).map((field) => field.label);
    if (pathOf(zip, local + LOCAL_SIZE, nameEnd) !== entry.name) {
      differing.unshift("name");
    }
    if (differing.length > 0) {
      refuse(`has a local header that differs from the central directory in: ${differing.join(", ")}`);
    }
    if (dataStart + entry.compressedSize > directoryOffset) {
      refuse("has data that runs past the start of the central directory");
    } else {
      entry.dataStart = dataStart;
      entry.recordEnd = dataStart + entry.compressedSize;
    }
  } else {
    refuse("has no local header where the central directory points");
  }
  if (zip64) {
    refuse("uses ZIP64");
  }
}

// Returns the entry's uncompressed bytes, or null with a reason when they cannot be read.
function readEntryBytes(zip, entry, refuse) {
  const data = zip.subarray(entry.dataStart, entry.recordEnd);
  if (entry.method === METHOD_STORED) {
    return data;
  }
  try {
    // The cap keeps a crafted stream from inflating without bound.
    const inflated = inflateRawSync(data, { info: true, maxOutputLength: Math.max(entry.size, 1) });
    if (inflated.engine.bytesWritten !== data.length) {
      refuse(`holds ${data.length - inflated.engine.bytesWritten} bytes after its deflate stream`);
    }
    return inflated.buffer;
  } catch {
    refuse(`does not inflate to the ${entry.size} bytes its header states`);
    return null;
  }
}

// The bytes are read only when the headers hold: a refused header already says why the
// entry cannot be trusted, and its sizes or method may not describe the data.
function checkFile(zip, entry, expected, headersHold, refuse) {
  const unixType = (entry.externalAttributes >>> 16) & UNIX_TYPE_MASK;
  if ((unixType !== 0 && unixType !== UNIX_REGULAR) || entry.externalAttributes & DOS_DIRECTORY) {
    refuse("is not a regular file");
  }
  if (!expected.has(entry.name)) {
    refuse("is not in the addon at the tag");
    return;
  }
  const wanted = expected.get(entry.name);
  if (wanted === null || !headersHold) {
    return;
  }
  const bytes = readEntryBytes(zip, entry, refuse);
  if (bytes === null) {
    return;
  }
  if (bytes.length !== entry.size) {
    refuse(`holds ${bytes.length} bytes, and its header states ${entry.size}`);
  }
  if (crc32(bytes) !== entry.crc) {
    refuse("has a CRC-32 that does not match its bytes");
  }
  if (!bytes.equals(wanted)) {
    refuse(entry.name === LIST_PATH ? "is not the list of the tag's files" : "differs from the blob at the tag");
  }
}

function checkFolder(entry, folders, refuse) {
  const unixType = (entry.externalAttributes >>> 16) & UNIX_TYPE_MASK;
  if (unixType !== 0 && unixType !== UNIX_DIRECTORY) {
    refuse("is neither a regular file nor a folder");
  }
  if (!folders.has(entry.name.slice(0, -1))) {
    refuse("is a folder that holds none of the tag's files");
  }
  if (entry.size !== 0 || entry.compressedSize !== 0) {
    refuse("is a folder entry that holds data");
  }
}

// Returns every folder above the given paths.
function foldersOf(paths) {
  const folders = new Set();
  for (const path of paths) {
    for (let slash = path.indexOf("/"); slash >= 0; slash = path.indexOf("/", slash + 1)) {
      folders.add(path.slice(0, slash));
    }
  }
  return folders;
}

// The entries, sorted by where they start, must run from the first byte to the central
// directory with nothing between: a reader that walks local headers would find a
// record hidden in a gap.
function checkLayout(entries, directoryOffset, reasons) {
  if (entries.some((entry) => entry.recordEnd === undefined)) {
    // A record of unknown length leaves every gap after it unknown; it has its own reason.
    return;
  }
  let covered = 0;
  for (const entry of [...entries].sort((a, b) => a.localOffset - b.localOffset)) {
    if (entry.localOffset > covered) {
      const gap = entry.localOffset - covered;
      reasons.push(
        covered === 0
          ? `${gap} bytes sit before the first entry`
          : `${gap} bytes sit between entries, before ${readable(entry.name)}`,
      );
    } else if (entry.localOffset < covered) {
      reasons.push(`${readable(entry.name)} overlaps the entry before it`);
    }
    covered = Math.max(covered, entry.recordEnd);
  }
  if (covered !== directoryOffset) {
    reasons.push(`${directoryOffset - covered} bytes sit between the last entry and the central directory`);
  }
}

function checkNames(entries, expected, reasons) {
  const listed = new Map();
  for (const entry of entries) {
    listed.set(entry.name, (listed.get(entry.name) ?? 0) + 1);
  }
  for (const [name, count] of listed) {
    if (count > 1) {
      reasons.push(`${readable(name)} is listed ${count} times`);
    }
  }
  for (const [path, bytes] of expected) {
    if (bytes !== null && !listed.has(path)) {
      reasons.push(`${readable(path)} is missing`);
    }
  }
  // Folders count too: two spellings of one folder merge on a case-insensitive disk.
  const names = [...listed.keys()].map((name) => (name.endsWith("/") ? name.slice(0, -1) : name));
  const spellings = new Map();
  for (const name of new Set([...names, ...foldersOf(names)])) {
    const folded = readable(name).toLowerCase();
    spellings.set(folded, [...(spellings.get(folded) ?? []), readable(name)]);
  }
  for (const group of spellings.values()) {
    if (group.length > 1) {
      reasons.push(`names that differ only by case: ${group.sort().join(", ")}`);
    }
  }
}

function checkZip(zip, expected, reasons) {
  const end = readEndRecord(zip, reasons);
  const entries = end === null ? null : readCentralDirectory(zip, end, reasons);
  if (entries === null) {
    return;
  }
  const folders = foldersOf(expected.keys());
  for (const entry of entries) {
    const refuse = (what) => reasons.push(`${readable(entry.name)} ${what}`);
    const reasonsBefore = reasons.length;
    checkHeaders(zip, entry, end.directoryOffset, refuse);
    if (entry.name.endsWith("/")) {
      checkFolder(entry, folders, refuse);
    } else {
      checkFile(zip, entry, expected, reasons.length === reasonsBefore, refuse);
    }
  }
  checkNames(entries, expected, reasons);
  checkLayout(entries, end.directoryOffset, reasons);
}

function main() {
  const [zipPath, tag, ...rest] = process.argv.slice(2);
  if (!zipPath || !tag || rest.length > 0 || tag.startsWith("-")) {
    throw new SetupError("usage: node scripts/check-release-zip.mjs <zip> <tag>");
  }
  let zip;
  try {
    zip = readFileSync(zipPath);
  } catch (error) {
    throw new SetupError(`cannot read ${zipPath}: ${error.message}`);
  }
  const reasons = [];
  const expected = readExpectedFiles(resolveCommit(tag), reasons);
  checkZip(zip, expected, reasons);
  if (reasons.length > 0) {
    for (const reason of reasons) {
      console.error(`refused: ${reason}`);
    }
    return 1;
  }
  console.log(`OK ${zipPath}`);
  return 0;
}

// Sets the exit code and lets the process end on its own, so a long list of reasons
// reaches a pipe whole.
try {
  process.exitCode = main();
} catch (error) {
  if (!(error instanceof SetupError)) {
    throw error;
  }
  console.error(`error: ${error.message}`);
  process.exitCode = 2;
}
