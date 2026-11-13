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
| A published release lacks a trust document its tag holds | [Hosting](#hosting), its second point |

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

The embedded document is the text of the constant in `self_update/embedded_trust_document.gd`, the
one line of the highest document in `trust/`. It is read without checking its signatures, since the
release's own signature carries it. Steps 1, 3 and 4 still apply to it, without the previous
version, and one that fails them reads as empty. An empty one gives no chain and no trusted key, so a
toolkit built with it offers updates as links only.

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
It asks the release it is about to verify, at `releases/download/v<version>/trust-N.json`, beside that
release's manifest and signature. A client that already holds that release's latest document makes one
request, for the document after it, and the 404 ends the walk.
An embedded document that reads as empty means no walk, and a release an earlier session kept is
offered at a start without a request. No walk runs while an update is staged.
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

The examples go from `trust-7` to `trust-8` and ship release `X.Y.Z`. Run them from the repo root.
`<keys>` is a folder outside the checkout, for the private keys.

A planned rotation overlaps the keys, so no client meets a release it refuses:

1. `trust-8` adds the new key and keeps the old one. It ships with release `X.Y.Z`, the first one
   the new key signs.
2. A later document, `trust-9`, drops the old key. It ships with the next release, which the new key
   also signs.

A leak skips the overlap: the document that adds the new key drops the leaked one at once (see
[A leaked release key](#a-leaked-release-key)). Any key a document lists can sign a release, so a
key stays trusted for as long as the latest document lists it. Root keys are replaced the same way:
one document adds the new roots, and a later one, signed by a new root, drops the old ones. The
maintainer's project-neutral playbook, *Signed-update key rotation*, holds the pattern. It is kept
outside this repository.

A document reaches clients only as an asset of a release, so a rotation is an ordinary release whose
tag holds the new document. `scripts/publish-release.sh` runs the GitHub side of steps 2 and 3 and
checks each result itself.

### 1. Build and sign the document, then land it

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -out <keys>/new-release.pem
openssl pkey -in <keys>/new-release.pem -pubout -out new-release.pub.pem
scripts/trust-document.sh build trust/trust-7.json --add-release new-release.pub.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/root-1.pem
scripts/trust-document.sh verify trust/trust-7.json trust/trust-8.json
```

- `--add-release` and `--add-root` take PEM **public** keys and refuse a private one. `build` keeps
  the threshold unless you pass `--threshold T`. `--drop-release` and `--drop-root` take the key's
  public half too. If that file is gone, `scripts/trust-document.sh show trust/trust-7.json`
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
`trust-8` stops every client at 7. Merging hosts nothing: no client sees `trust-8` before step 3.

### 2. Release X.Y.Z, signed by the new key

From the merged `main`, tag `vX.Y.Z` so that it embeds `trust-8`, and run the release as
`RELEASING.md` describes, up to and including `attach`: `check`, `draft`, the sign, `attach`. `draft`
uploads `trust-2.json` through `trust-8.json` from the tag beside the zip and the manifest, and hands
the zip over for the sign. The sign uses the new key, in the account the maintainer signs releases
from (see [Custody](#custody)), from a fresh anonymous clone of `main`:

```sh
scripts/sign-release.sh vX.Y.Z <the zip draft handed over> <keys>/new-release.pem
```

`sign-release.sh` reads no manifest it is handed. It verifies the tag's documents from the pinned
`trust-1` up to `trust-8`, checks the zip against the tag, writes the manifest itself and signs only
that; `RELEASING.md` lists every check. It keeps the `.sig` only when a release key of the highest
trust document at the tag, here `trust-8`, verifies it. It asks once for the passphrase. Stop before
`publish`.

### 3. Publish the release, with its documents

```sh
scripts/publish-release.sh publish vX.Y.Z
```

One command publishes the release, and the documents go public with it, since they are its assets:
no client can see `vX.Y.Z` without `trust-8` beside it. Before it publishes, the script downloads
every asset back. Each document must be byte-equal to the tag's `trust/trust-K.json`, since CI read
the committed bytes and not the uploaded ones, and every document the current latest release carries
must be byte-equal in this one. Then it publishes the release and checks it, as `RELEASING.md` lists.

No `trust-N` tag or release exists, and none should ever be made: a client asks only the release it is
verifying.

Never change a document once a release has carried it. Its content verifies itself, so this is a rule
and does not depend on a repository setting. With immutable releases on, a published release's assets
can never be replaced, so a bad `trust-8` in a published release stays there for good.

### 4. Drop the old key, with the next release

```sh
scripts/trust-document.sh build trust/trust-8.json --drop-release old-release.pub.pem
scripts/trust-document.sh sign trust/trust-9.json <keys>/root-1.pem
scripts/trust-document.sh verify trust/trust-8.json trust/trust-9.json
```

Land `trust-9` as in step 1, then release the next version as in steps 2 and 3, signed by the new
key. That release carries `trust-2.json` through `trust-9.json`. From then on only the new key is
trusted.

### What clients see when a document drops a key

- A client that holds the dropping document refuses the dropped key.
- An update staged earlier and signed by the dropped key is refused at the exit only when this
  machine's store already holds the dropping document. The installer runs no walk while a release
  is staged, so on a machine with no other project walking, a stage verified before the rotation
  installs at exit.
  A refusal reads "the update is not signed by a key this toolkit trusts", and its stage and zip are
  deleted. A start that finds the key dropped before any exit says the same.
- Neither notice offers a download: a hand download checks no signature, and in a leak
  `/releases/latest` can be the old key's release too. Each says "The toolkit offers the next
  release once it is published and checked." The next release comes through the ordinary check. The
  security-check message shows neither the GitHub button nor the store button: the first would open
  the release just refused, and the store's copy is a separate artifact this chain does not check,
  so the badge offers no unverified copy of the release.
- A client takes the dropping document only from a release that carries it, so in the ordinary ritual it
  does not hold that document while the latest release is still one the dropped key signed. A client whose update check
  last saw an older release walks that release's documents, and can still install a genuine release
  the dropped key signed until its next check.
- A machine that installs the release by hand starts from the document it embeds, so it never
  trusts the dropped key, even with an empty store.

In a planned rotation the dropped key signed no release since the one before the overlap, so only
an update staged that long ago meets these refusals.

## A leaked release key

Run the rotation above, now, with a new key pair, and with the leaked key under `--drop-release` in
step 1, so `trust-8` drops it at once. Step 4 then has nothing left to drop. Publish a security
advisory on the repository, saying which key leaked and that a client which has not yet seen the new
document still trusts it. See the first of [the limits](#the-limits).

## A leaked root key

Replace it in a next document. A root change signs no release, so it needs no new release key:

```sh
scripts/trust-document.sh build trust/trust-7.json --add-root new-root.pub.pem --drop-root leaked-root.pub.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/leaked-root.pem
scripts/trust-document.sh sign trust/trust-8.json <keys>/new-root.pem
scripts/trust-document.sh verify trust/trust-7.json trust/trust-8.json
```

The previous document's roots must vouch for this one, so with a threshold of 1 and one root, the
leaked key itself has to sign. With more roots, sign with the ones that did not leak wherever the
thresholds allow it. Then continue with the constant and the pull request, and ship the document in a
patch release at once, through the ordinary ritual
([steps 2 and 3](#2-release-xyz-signed-by-the-new-key)): a document goes out only as an asset of a
release, and the tag's run takes about an hour. Publish an advisory. Treat it as urgent: see the
threshold line in [the limits](#the-limits).

With no leak, replace a root by the overlap: one document adds the new root, and a later one drops
the old, each carried by a release. The same commands do it, and `--threshold T` sets the
threshold.

## The emergency stop

A document with no release keys is accepted and trusts nothing, so a client that holds it refuses
every update, staged ones included:

```sh
scripts/trust-document.sh build trust/trust-7.json --drop-release old-release.pub.pem
```

Pass `--drop-release` once per listed key. `build` warns that the document stops all updates, and
`verify` says so too. Sign and land it as in step 1, then ship it as
[the stop release](#the-stop-release): a patch release whose tag embeds it, with no signature, since
no key it lists could sign one. Every client that may install updates takes the stop document from
that release when it checks it; a client that installs nothing from the editor fetches no document,
and needs none. It undoes nothing already installed. To lift it, run the rotation with
`--add-release` alone, since there is no key left to drop.

### The stop release

The stop release is a patch release, `vX.Y.Z`, whose tag embeds the stop document. It carries the zip,
the manifest and `trust-2.json` through the stop document, and no `.sig`. A client verifying it walks
through the stop document, finds no release key in the latest one, and refuses before it asks for
the manifest or its signature.

`scripts/publish-release.sh` publishes no release without a signature, so the last step is by hand:

1. Tag `vX.Y.Z` from the merged `main` and let the tag's run finish, as for any release.
2. `scripts/publish-release.sh check vX.Y.Z`, then `draft vX.Y.Z`, which uploads the documents too.
3. Skip the sign and `attach`. Download the draft's assets into an empty folder and compare each
   document with the tag's, since CI read the committed bytes and not the uploaded ones:
   `git show vX.Y.Z:trust/trust-K.json | cmp - <an-empty-folder>/trust-K.json`.
4. The maintainer publishes the draft: `gh release edit vX.Y.Z --draft=false --latest`.

**This path has not yet been run against a real release here.** Check each result, and stop at the
first surprise: once published, the release cannot be withdrawn.

## Hosting

- Every release carries the whole chain after the first document. A release whose tag's highest
  document is N publishes `trust-2.json` through `trust-N.json` as assets beside its zip, each
  byte-equal to the tag's `trust/trust-K.json`. A release whose tag holds `trust-1` alone, as 1.2.0's
  does, publishes none. The documents stay outside the zip and the manifest: a client learns the
  manifest's key from them, and fetches the zip only after the manifest verifies. `trust-1` is committed
  and never hosted, since the first number a client can ask for is 2.
- A client asks only the release it is verifying, so every later release must carry every document, for
  good. A fresh install of an old release years later walks from its own embedded document through
  every one after it, all read from the latest release. A release published without one of them ends
  the walk there for every client that lacks that document, and such a client refuses the release if a
  key it has not yet learned signed it. Nothing can be added to a published release; the next release,
  carrying the whole chain, recovers those clients.
- `trust/` at the repo root is the source, and it never ships. `trust/*.json` is pinned to LF, so a
  checkout cannot change the bytes publishing uploads.
- `trust/released-manifests.txt` holds one line per published release, its version and its manifest's
  SHA-256. No client reads it. A later document can pin a release from it, and git history shows any
  later edit.

## Custody

Real private keys stay out of this repository and out of every workflow. The tools read a private key
from a PEM file you name. `trust-document.sh` uses no network. `sign-release.sh` uses none but
`git ls-remote origin`, which it asks for the tip of `main` and for the tag; it never calls `gh`.

`trust-1` lists two root keys, with a `root_threshold` of 1, and one release key, and both roots
signed it. Two roots buy availability: losing one costs nothing.

| Key | Kind | Private half | Its passphrase | Copies off its machine |
|---|---|---|---|---|
| Release key | RSA-2048 | An encrypted PEM on the maintainer's machines; releases are signed from an account that runs no coding agent | Its own entry in the maintainer's password manager | One, the encrypted PEM in that password manager |
| Root 1 | RSA-4096 | An encrypted PEM on one machine only | Its own entry in the password manager | None |
| Root 2 | RSA-4096 | An encrypted PEM on a second machine only | Its own entry in the password manager | None |

- **No root's private half ever moves between machines, and no root is in the password manager.**
  It holds the release key and every passphrase, and the roots are how a leak of the release key is
  recovered, so one breach of it must not reach them. Only public data travels: public halves, and a
  document being signed.
- **Each root is one encrypted file, with no paper copy,** until the roots are replaced by keys
  held in hardware. The accepted risk: losing both machines before then loses every root, which
  strands the release key (see [the limits](#the-limits)).
- **The restore test.** Each private half, the release key's password-manager copy included, is
  decrypted once with its passphrase pasted from the password manager. Its public half, written out
  with `openssl pkey -pubout`, must have the same DER SHA-256 as the key `trust-1` lists. No
  signature is made.
- **The maintainer types every command that reads a private key** (generate, sign, decrypt) and
  every publish, in their own terminal. A coding agent helping with a release prepares those
  commands as text, runs the rest (`publish-release.sh check`, `draft` and `attach`,
  `sign-release.sh --verify`, `trust-document.sh build`, `show`, `verify` and `release-keys`), and
  reads only public files. A guard on the maintainer's machines refuses an agent's command that
  names the keys folder, a private PEM, or a signing or publishing entry point.
- **Releases are signed in a separate admin account that runs no coding agent.** It holds the
  release key and has git, bash, openssl and node, with no GitHub login and no Godot. The maintainer
  signs there from that account's own login session, never through `su` or `sudo` from a terminal of
  the account agents work in, and from a fresh anonymous clone of `main`. On the machine releases
  are signed on, the account agents work in holds no key file. Only public bytes cross between the two, through a folder both
  can reach: the draft's zip one way, the manifest and its `.sig` the other. The maintainer types
  `publish` in the account that made the draft.
- Private halves are named `root-1.pem`, `root-2.pem` and `release.pem`, and public halves end in
  `.pub.pem`, so the guard can tell them apart.

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

Where a client downloads from is fixed the same way, compiled into `release_assets.gd` and
`update_downloader.gd`:

| What | Value | For someone who stays on 1.2.0 |
|---|---|---|
| Host of every first request | `https://github.com` | Every file must stay reachable there. |
| Hosts a redirect may reach | `github.com`, or a subdomain of `githubusercontent.com` other than `raw.githubusercontent.com` and its subdomains, over HTTPS, at most 5 hops | A release asset served from anywhere else is refused. |
| Paths | `/NPGameDev/godot-mcp-toolkit/releases/download/v<version>/<asset>`, for a trust document as for a release's other files | Every release must stay at this path, with every document after the first beside it. |
| Asset names | `trust-N.json`, `godot-mcp-toolkit-<version>.zip`, `godot-mcp-toolkit-<version>.update.json` and `godot-mcp-toolkit-<version>.update.json.sig` | A release must publish these exact names. |

Each URL is built from the version, and a document's from its number too, never taken from a reply. A
test-only variable, `GODOT_MCP_UPDATE_CHECK_HOST`, can replace the scheme and host with a loopback
address and nothing else. A server there can serve only what the keys signed: it can withhold the
next document, which ends the walk, or a release's files, which stops that install, but it cannot
add a key or make a release the chain does not trust install.

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
- **Every release must carry the whole chain.** A client asks the release it is verifying for exactly
  the next document, so a release that lacks one stops every client behind it there.
- **Whoever can publish releases can hide a revocation by leaving it out.** A release published without
  the revoking document, or an older release kept as the latest, leaves clients on the keys they hold.
  `publish-release.sh` refuses a release that lacks a document its tag holds, or that drops or changes
  one the latest release carries, and a version that is not above the latest. It cannot refuse a release
  that stays the latest because nothing newer is published, and someone with the repository's publish
  rights need not use it.
- **The signing script comes from `main`.** `sign-release.sh` runs from a clone of `main` and reads
  the passphrase, so a malicious change merged there could take the key. Review of what lands on
  `main`, and the maintainer reading the clone's own `scripts/` changes since the copy last reviewed,
  before running it, are what stand against it. The sign's display covers the tag, not the clone's
  tip, and comes from the script itself, so neither it nor the script's checks can.
- **It cannot force an update.** Someone with repo access can keep an old release as latest. A manifest's
  `expires_at` informs and never refuses.
- **With no absolute data folder there is no store.** With no `APPDATA` or `HOME`, Godot can answer `.`, the
  working directory, which could be the project. The client then writes nothing and takes no document, so
  its chain ends at the embedded one.
- **The exit does not re-read the install mode.** The click on Update was the consent, and Don't install,
  or switching to `manual` in the editor, takes it back before the exit. The exit checks the guards, the
  trust and the version order again, and a refusal there gives its reason at the next start.
- **The exit does not wait for a file scan.** On Windows, a plain close during a scan can fail the first
  rename, which leaves the update waiting for the next close.

## Going back

The applier refuses anything not newer, so going back never runs through the update path, and the chain
has no part in the move itself. Going back undoes no revocation: the older version reads the same store
and walks from its own embedded document to the same latest one. A machine that only ever saw a newer
embedded document has no stored files for the numbers before it, so the older version trusts what its
embedded document lists until it has fetched them, from the next release it verifies. That is one more
reason every release carries the whole chain.

A release signed by a dropped key cannot be reached by an update, since no client that holds the dropping
document trusts that key.
