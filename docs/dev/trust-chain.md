# Trust chain: rotating and revoking the keys behind self-update

Self-update trusts a release only when its manifest is signed by a key the latest trust document
lists. This note holds the procedures for changing those keys, what a shipped client can never
change, and what the chain does not protect against. It is written for the maintainer during a key
leak and for anyone auditing the design.

The reader is `addons/godot_mcp_toolkit/self_update/trust_chain.gd`. The tool is
`scripts/trust-document.sh`, which needs bash, openssl and awk and no network.

## If something just went wrong

| What happened | Go to |
|---|---|
| A release key leaked | [A leaked release key](#a-leaked-release-key) |
| A root key leaked | [A leaked root key](#a-leaked-root-key) |
| No release can be trusted right now and no replacement is ready | [The emergency stop](#the-emergency-stop) |
| A release key's private half is lost | [Rotating a release key](#rotating-a-release-key), with no hurry |
| Every root key leaked or is lost | [The limits](#the-limits) |
| `releases/latest` returns a `trust-N` tag | [Step 3 of the rotation](#3-publish-the-document) |

## How it works

A release embeds a **trust document**: its root keys, how many of them must sign the next document,
and its release keys. Root keys sign only documents, and a release key signs manifests. A key's
status is whether the latest document lists it, so a rotation and a leak are the same act.

A document file is one line of JSON:

```json
{"document": "<base64>", "signatures": ["<base64>", "..."]}
```

The decoded document is
`{"format": 1, "version": N, "root_keys": [pem, ...], "root_threshold": T, "release_keys": [pem, ...]}`.
Signatures are RSA with SHA-256 over the decoded bytes, as a manifest's is.

A client reads a next document in this order, and any failure refuses the whole file:

1. The file is at most 1 MiB and parses, its document decodes, and its signatures fit the caps below
   and decode.
2. At least the previous document's `root_threshold` of its distinct roots each verify a signature.
   Nothing inside the document is read before this.
3. `format` is exactly 1 and `version` is exactly the previous version plus 1.
4. `root_keys` is non-empty and every root loads. `root_threshold` is a whole number from 1 up to
   the distinct roots. `release_keys` is a list, which may be empty.
5. At least the new `root_threshold` distinct new roots each verify a signature.

One key in two PEM layouts counts once. A release key that does not load counts as no key, and a
field the reader does not know is ignored.

The embedded document is the text of the constant in `self_update/embedded_trust_document.gd`. It
is read without checking its signatures, since the release's own signature carries it. Steps 1, 3 and
4 still apply to it, without the previous version, and one that fails them reads as empty. While it
is empty there is no chain and no trusted key, so the toolkit offers updates as links only.

### The store

Accepted documents live per machine in `godot_mcp_toolkit/trust` inside the OS's data folder:
`%APPDATA%`, `~/Library/Application Support`, or `$XDG_DATA_HOME` or `~/.local/share`. A revocation
is a fact about the keys, not about a project.

The files cannot add trust. Every load walks from the embedded document and verifies each file
again, and the first missing or invalid file ends the walk. Deleting the folder only undoes a
revocation until the client next takes those documents. A document counts once it has been
written, read back and verified. If that write fails, the chain stays where it was. A crash between
the write and the rename leaves a `trust-N.json.<pid>.tmp` that no walk removes, and it is only bytes,
since no walk reads it.

The chain has no network of its own. The owner of the fetch asks `next_version()`, downloads that
file and hands its bytes to `accept()`. Checking a signature only reads files, so the applier can
verify at the editor's exit, offline, from what the store holds.

The installer runs that fetch just before it verifies a newer release and on each click on Update.
An up-to-date client asks for nothing, an empty embedded document means no walk, and a release an
earlier session kept is offered at a start without a request. No walk runs while an update is staged.
A 404 ends the chain. A timeout, a 5xx, a TLS failure, an off-list redirect or an invalid document
leaves the badge with a sentence saying what failed. A click retries now and a new start
retries; there is no timer. A 404 on the release's own manifest or signature comes after the walk.
At a start nobody clicked it stays quiet: the log records it, the badge keeps the plain offer with no
sentence and no Update, and a later start verifies again, so Update appears once the assets are up.
An editor left open does not check that version again until its next start or a newer version.
Only when a click reaches that 404, as a retry after another failure can, the badge says "This release
isn't ready to install from the editor yet. Try Update again later." and Update stays clickable. A
security failure shows no "Download from GitHub": the sentence says the update won't install, and
the button would open the release just refused. The other failures keep it. A document with no
release keys does not stop the walk, because only the next document can lift the emergency stop.

## Rotating a release key

The examples go from `trust-7` to `trust-8` and publish release `X.Y.Z`. Run them from the repo root.
`<keys>` is a folder outside the checkout, for the private keys. The order matters: the document
goes up minutes before the release signed by the new key, and the old key is dropped at once. Any
key a document still lists can sign a release, so keeping the old one listed "for a while" keeps it
trusted.

**The publishing commands below were read from GitHub's documentation and have not yet been run
against a real release here.** That includes a release with `--prerelease --latest=false` leaving
`releases/latest` alone, which is why step 3 ends by checking it. Check each command's result as the
step says, and stop at the first surprise.

### 1. Build and sign the document, then land it

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -out <keys>/new-release.pem
openssl pkey -in <keys>/new-release.pem -pubout -out new-release.pub.pem
scripts/trust-document.sh build trust/trust-7.json --add-release new-release.pub.pem --drop-release old-release.pub.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/root-1.pem
scripts/trust-document.sh verify trust/trust-7.json trust/trust-8.json
```

- `--add-release` and `--add-root` take PEM **public** keys and refuse a private one. `build` keeps
  the threshold unless you pass `--threshold T`. If `old-release.pub.pem` is gone, `scripts/trust-document.sh show trust/trust-7.json`
  prints every listed key as a JSON string with `\n` for each line break: save it as a file with real
  line breaks. Keys match by content, not layout.
- Repeat `sign` once per root until `verify` is satisfied. A document needs a threshold of the previous
  roots and a threshold of its own, and a root in both lists counts for both with one signature.
  `sign` does not check that its key is a root; `verify` counts only roots. `sign` reads the passphrase
  from a pipe on stdin, and without a pipe openssl prompts once.
- `verify` must print `version 8 holds`, with enough signers on each line. It is stricter than the
  reader, because a document the reader only tolerates should never be made: it also refuses a release
  key that does not load or is not RSA, a repeated JSON field, and a file name that disagrees with
  its version.

Copy the new file's one line into `addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd`,
in single quotes so its double quotes need no escaping:

```gdscript
const DOCUMENT := '<the one line of trust/trust-8.json>'
```

A unit test fails when that constant is not the highest document in `trust/`.

Commit both files in a pull request and merge it once CI is green. CI's unit job, on every supported
Godot version, walks `trust/` with the real reader from `trust-1` on: each document against the one
before it, each `trust-N.json` carrying version N, and the constant held to its own roots.

**Host nothing before CI has read it.** The walk requires exactly the next version, so a mis-signed
`trust-8` stops every client at 7. Merging hosts nothing, so the old key stays trusted until step 3.

### 2. Sign the release draft with the new key

From the merged `main`, have release `X.Y.Z` up as an unpublished draft, so that it embeds `trust-8`.
`release.yml` publishes on the tag push today and has no draft mode yet; do not push the tag until it does.
Then sign the manifest the release workflow built, never a local build:

```sh
gh release download vX.Y.Z --pattern 'godot-mcp-toolkit-X.Y.Z.update.json'
scripts/sign-release.sh godot-mcp-toolkit-X.Y.Z.update.json <keys>/new-release.pem new-release.pub.pem
gh release upload vX.Y.Z godot-mcp-toolkit-X.Y.Z.update.json.sig
```

`sign-release.sh` prompts once for the passphrase, or reads it from a pipe on stdin.

### 3. Publish the document

Upload the committed bytes from the merged `main`, compare them, then publish:

```sh
gh release create trust-8 --draft --prerelease --latest=false --title trust-8 --notes "Trust document 8." trust/trust-8.json
gh release download trust-8 --pattern trust-8.json --dir <an-empty-folder>
openssl dgst -sha256 trust/trust-8.json <an-empty-folder>/trust-8.json
gh release edit trust-8 --draft=false --prerelease --latest=false
gh api repos/NPGameDev/godot-mcp-toolkit/releases/latest --jq .tag_name
```

- The two hashes must match, since CI read the committed bytes and not the uploaded ones. If they
  differ, `gh release delete trust-8 --yes` while it is still a draft and upload again.
- The last command must print a `v` tag. A `trust-N` that became latest stops the update check, which
  cannot read that tag as a version. To repair it, run `gh release edit v<the last version> --latest`
  and run the check again.

Only `release.yml` fires on tags, on `v*`, so this tag starts no release workflow.

Never edit a document after it is published. Its content verifies itself, so this is a rule and does
not depend on a repository setting. With immutable releases on, a tag name can never be used again, so
a bad `trust-8` stays bad for good.

### 4. Publish the release, minutes later

```sh
gh release edit vX.Y.Z --draft=false
gh api repos/NPGameDev/godot-mcp-toolkit/releases/latest --jq .tag_name
```

The last command must print `vX.Y.Z`.

### What clients see

- A client that holds `trust-8` trusts the new key and refuses the old one.
- An update staged earlier and signed by the old key is refused at the exit only when this machine's
  store already holds the new document. The installer runs no walk while a release is staged, so on
  a machine with no other project walking, a stage verified before the rotation installs at exit.
  A refusal reads "the update is not signed by a key this toolkit trusts", and its stage and zip are
  deleted. A start that finds the key dropped before any exit says the same.
- Neither notice offers a download: a hand download checks no signature, and in a leak
  `/releases/latest` can be the old key's release too. Each says "The toolkit offers the next
  release once it is published and checked." The next release comes through the ordinary check. The
  security-check message shows no GitHub button either, since it would open the release just
  refused; its store button stays. When the Asset Store lists the refused version, that button is
  enabled and opens the store's listing, a separate artifact this chain does not check.
- A client behind on the old latest refuses that release from the moment it holds `trust-8` until
  the new one is out. That gap fails safe.
- A machine that installs the release by hand starts from the `trust-8` it embeds, so it never
  trusts the old key, even with an empty store.

## A leaked release key

Run the rotation above, now, with a new key pair and the leaked key under `--drop-release`. Then publish
a security advisory on the repository, saying which key leaked and that a client which has not yet
seen the new document still trusts it. See the first of [the limits](#the-limits).

## A leaked root key

Replace it in a next document. A root change signs no release, so steps 2 and 4 do not apply:

```sh
scripts/trust-document.sh build trust/trust-7.json --add-root new-root.pub.pem --drop-root leaked-root.pub.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/leaked-root.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/new-root.pem
scripts/trust-document.sh verify trust/trust-7.json trust/trust-8.json
```

The previous document's roots must vouch for this one, so with a threshold of 1 and one root, the
leaked key itself has to sign. With more roots, sign with the ones that did not leak wherever the
thresholds allow it. Then continue with the constant, the pull request and
[step 3](#3-publish-the-document), and publish an advisory. Treat it as urgent: see the threshold line
in [the limits](#the-limits).

The same commands, with no leak, retire or add a root, and `--threshold T` sets the threshold.

## The emergency stop

A document with no release keys is accepted and trusts nothing, so a client that holds it refuses
every update, staged ones included:

```sh
scripts/trust-document.sh build trust/trust-7.json --drop-release old-release.pub.pem
```

Pass `--drop-release` once per listed key. `build` warns that the document stops all updates, and
`verify` says so too. Sign, land and publish it as in steps 1 and 3. It reaches only the clients that
fetch it, and it undoes nothing already installed. To lift it, run the rotation with `--add-release`
alone, since there is no key left to drop.

## Hosting

- Every `trust-N` from 2 up stays hosted as `trust-N/trust-N.json` under this repository's releases, and
  is never deleted. A fresh install of an old release years later walks from its own embedded document
  through every one after it. `trust-1` is committed and never hosted, since the first number a client
  can ask for is 2.
- `trust/` at the repo root is the source, and it never ships. `trust/*.json` is pinned to LF, so a
  checkout cannot change the bytes publishing uploads.
- `trust/released-manifests.txt` holds one line per published release, its version and its manifest's
  SHA-256. No client reads it. A later document can pin a release from it, and git history shows any
  later edit.

## Custody

Real private keys stay out of this repository and out of every workflow. The tools read a private key
from a PEM file you name, and use no network. Root keys stay offline.

## What a shipped client can never change

A client that stays on a release keeps its copy of the reader for good. Every document ever published
must stay readable by the oldest client anyone may still run, and 1.2.0 is the first with a chain. A
later release can change these for itself, never for someone who stays on 1.2.0.

The caps are in `trust_chain.gd`, where each comment ends in "Permanent". This table holds the reasons.

| What | Value | Why | For someone who stays on 1.2.0 |
|---|---|---|---|
| Size of a document file | 1 MiB (1,048,576 bytes) | The reader holds the whole file before any signature is checked. A document with a handful of keys is a few kilobytes. | A larger `trust-N` is refused, and the client stops at N-1. |
| Signatures in a file | 16 | Each root is tried against each signature, so this bounds the work an unverified file can ask for. | More are refused. A document that replaces all its roots needs both thresholds' signers in those 16. |
| Size of one signature | 4,096 bytes | The same bound. An RSA-4096 signature is 512 bytes. | A signature over this is refused, on a document or a manifest. |
| Documents one instance accepts | 32 | Each one is read, written, read back and verified, so one check stays short. | A client more than 32 behind stops at 32 and carries on at the next check. The next load walks every stored file with no cap, so there is no total limit, and a load's cost grows with the chain. |
| `format` | 1, never bumped | Anything else is refused, so a bump would strand every client that stays. | What is new goes in a field of its own, which 1.2.0 ignores. `root_keys` and `release_keys` stay lists of PEM strings for good: any other entry in `root_keys` refuses the document, and one in `release_keys` is no key. |
| Key expiry | None | Nothing reads a `not_after`. | A later client can enforce one. 1.2.0 trusts a key until a document drops it. |
| Signatures on a release | One is enough | A manifest has one `.sig`, and any listed key counts. | A later client can ask for more. 1.2.0 accepts one, so one stolen release key is enough until it is dropped. |

The download path is fixed the same way. Each client builds it from the number alone, as
`/NPGameDev/godot-mcp-toolkit/releases/download/trust-N/trust-N.json` on `https://github.com`. A
contributor-only variable can replace the host for a local test server, and a document's signatures
make another host harmless.

`build` writes only the fields it knows, and warns when it drops one from the previous document. Before
rotating past a document with a new field, teach the script that field, or the next document loses it.

## The limits

- **A client that has not seen the revoking document is exposed.** It still trusts the leaked key, so an
  attacker who holds that key and has repo access can publish a release it accepts. Every older release
  embeds a document that lists the keys of its time, so a fresh install starts in the same place.
- **With a threshold of 1, one root plus repo access can publish a next document.** A higher threshold
  needs that many roots.
- **If every root leaks, users reinstall by hand.** Anyone holding them can sign a next document, and a
  client cannot tell whose it is. The reinstalled release has to embed a new chain. That path is not rehearsed:
  `test/units/trust_folder_check.gd` walks `trust/` as one unbroken chain, so starting another means
  changing that check too.
- **If every root is lost, no document can ever be signed again.** The release key can then never change,
  and losing it strands every client until a hand reinstall.
- **Every `trust-N` must stay hosted.** A client needs exactly the next one, so a gap stops every client
  behind it.
- **It cannot force an update.** Someone with repo access can keep an old release as latest. A manifest's
  `expires_at` informs and never refuses.
- **With no absolute data folder there is no store.** With no `APPDATA` or `HOME`, Godot can answer `.`, the
  working directory, which could be the project. The client then writes nothing and takes no document, so
  its chain ends at the embedded one.

## Going back

The applier refuses anything not newer, so going back never runs through the update path, and the chain
has no part in the move itself. Going back undoes no revocation: the older version reads the same store
and walks from its own embedded document to the same latest one. A machine that only ever saw a newer
embedded document has no stored files for the numbers before it, so the older version trusts what its
embedded document lists until it has fetched them. That is one more reason every `trust-N` stays hosted.

A release signed by a dropped key cannot be reached by an update, since no client that holds the dropping
document trusts that key.
