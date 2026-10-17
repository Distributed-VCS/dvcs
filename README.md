# DVCS — A Blockchain-Based Decentralized Version Control System

A Git-like version control system where the *history* (who committed what,
in what order, on which branch, and who's allowed to push), the *review
workflow* (pull requests, approvals), and — if you want it — the *file
content itself*, all live in a Solidity smart contract instead of on a
single server. The contract is the shared source of truth that any number
of independent clients can read and write without trusting each other or a
central host.

Two parts:

- **`contracts/DVCS.sol`** — the on-chain contract: repositories, commits,
  branches, tags, pull requests, an identity registry, role-based access
  control, and chunked blob content.
- **`cli/`** — a command-line client written in [V](https://vlang.org),
  including a from-scratch Keccak-256 implementation, a minimal Ethereum ABI
  encoder/decoder, and real AES-256-GCM encryption (via V's stdlib), since V
  has no existing web3 tooling.

Everything below has been built and exercised end-to-end against a real
local chain (Hardhat), including the negative/failure cases — see "What's
been tested" at the end.

**New here?** Start with **`SETUP.md`** (nothing assumed pre-installed —
what to install, where from) and then **`TUTORIAL.md`** (a hands-on
walkthrough with real, tested output). This README is the reference; those
two are the guided path. **On Windows and don't want to set up WSL2
yourself?** See **`DOCKER.md`** instead — one install (Docker Desktop),
everything else happens inside a container. `VIDEO_SCRIPT.md` has a
scene-by-scene script if you're recording a demo — including
`scripts/demo.sh`, which runs the whole thing automatically (fresh chain,
fresh deploy, typed-out commands, timed pauses for narration) so you can
just talk over it.

## How it fits together

```
contracts/DVCS.sol      Solidity contract (Solidity ^0.8.24)
cli/                     V CLI source (all files form one `main` module)
  keccak.v               Keccak-256 (Ethereum flavor), from scratch
  hex.v                  hex <-> bytes helpers
  abi.v                  ABI encode_call() / decode_*() for the types used here
  rpc.v                  JSON-RPC client (eth_call, eth_sendTransaction, eth_getLogs, receipts, retry-with-backoff)
  crypto_local.v         AES-256-GCM encryption, PBKDF2 key derivation (local only)
  objects.v               local content-addressed blob store + Merkle root
  blobs.v                 chunking + push/fetch of blob content via BlobChunk events
  merge3.v                3-way file-tree merge (used by rebase and pr-merge divergence checks)
  ignore.v                .dvcsignore pattern matching
  changelog.v             local append-only audit trail of on-chain actions
  repo.v                  local repo state: config, refs, staging index, commit cache
  main.v                  command dispatch (every command below)
  *_test.v                unit tests (run with `v test .`) alongside the code they test
test/keccak_test/       standalone Keccak-256 self-test (known test vectors, separate binary)
test/integration/       full end-to-end test suite against a real local chain (see Testing below)
build/                  solc output goes here (generated, see below)
```

## Building

See **SETUP.md** for a complete from-scratch guide (nothing assumed
pre-installed). Short version if your environment is already set up:

### Contract

```bash
./scripts/compile-contract.sh
```
Wraps `solcjs --standard-json` with the settings this contract actually
needs — `viaIR: true` (its pull-request functions otherwise hit a
"stack too deep" error) and `evmVersion: paris` (for compatibility with
local dev chains that lag mainnet's latest opcodes), neither of which the
plain `solcjs --bin --abi` flags can express. Writes `build/DVCS.bin` and
`build/DVCS.abi`. Deploy them with `scripts/deploy.js` (see SETUP.md step
8) or any tool you like (Hardhat, Foundry, ethers.js, Remix, ...) — the CLI
just needs the resulting contract address.

### CLI

Requires the [V compiler](https://github.com/vlang/v) and, ideally,
[`tcc`](http://savannah.nongnu.org/projects/tinycc) as its C backend (see
SETUP.md step 3 and its Troubleshooting section for why `-cc tcc`
specifically — recent V builds can otherwise trigger a very slow,
memory-heavy internal self-check on a project this size):

```bash
cd cli
v -cc tcc -o dvcs .
```

Produces a single binary, `dvcs`. Run `dvcs help` or `dvcs help <command>`
at any time for the built-in reference, or see **TUTORIAL.md** for a
guided walkthrough.

---

## Core design decisions

### Two storage tiers: on-chain metadata, on-chain-or-off-chain content

**Always on-chain, in the contract:** repository identity/ownership,
every commit's parent hash(es) + Merkle tree root + message + author +
timestamp, branch pointers, tags, roles, pull requests, and the identity
registry. This is the part that gives you blockchain properties: nobody —
not even a repo's own maintainers — can silently rewrite history, push
without the right role, or force a branch backward, without that being a
public, permanent, auditable transaction.

**File content** can go either of two ways:
1. **On-chain via event logs (default).** Chunked and pushed as
   `BlobChunk` events. Cheap (~16 gas/byte instead of ~20000 gas/32 bytes
   for `SSTORE`), permanent, and readable by any client via
   `eth_getLogs` — no IPFS or other off-chain service required.
2. **Off-chain via a CID** — a commit can instead point at an IPFS hash or
   similar. The CLI defaults to mode 1 automatically when you `push`.

### The signing model (a deliberate scope decision)

The CLI submits transactions via `eth_sendTransaction` against accounts the
target node has already **unlocked** (Hardhat's local node, Anvil's dev
accounts, Ganache with `--wallet.unlockedAccounts`, etc.). It does **not**
hold private keys or sign raw transactions itself. This only works against
nodes where you control the accounts — a public testnet/mainnet needs real
key signing (`eth_sendRawTransaction` with a locally-held key), which isn't
built here.

### What "private" actually means here

Ethereum has no concept of private on-chain data — anyone running a node or
using a block explorer can read contract storage and event logs directly,
regardless of what any contract's access-control roles say those roles only
gate *writes*. So "private repository" here is implemented honestly:
marking a repo private makes the **CLI itself refuse to push unencrypted
file content** to it. The actual privacy comes from `crypto-init`
(AES-256-GCM) — see below. Commit metadata (messages, authors, branch
names, tree roots) is *always* public no matter what, since that has to be
verifiable by anyone syncing the chain.

---

## Command reference, with usage

### Setup

**`dvcs init`** — create `.dvcs/` in the current directory (object store,
refs, config). Run once per project.
```
dvcs init
```

**`dvcs remote <rpc-url> <contract-address> <account-address>`** —
configure which chain/contract/signer to use. The account must be unlocked
on that node.
```
dvcs remote http://127.0.0.1:8545 0xAbC...123 0xDeF...456
```

**`dvcs whoami`** — show your configured account and registered handle
(see Identity below).
```
dvcs whoami
```

### Repositories

**`dvcs repo-create <name> [--private]`** — register a new repository
on-chain, owned by your configured account. `--private` marks it private
(see "What private means" above) and means you'll need `crypto-init` before
any `push` succeeds.
```
dvcs repo-create myproject --private
```

**`dvcs repo-connect <owner-address> <name>`** — the "clone" path for
anyone who isn't the owner: computes the same deterministic repo id and
verifies the repo exists, but sends no transaction. You still need a role
granted via `member-add` before you can push.
```
dvcs repo-connect 0xAbC...123 myproject
```

**`dvcs set-private <true|false>`** — flip the on-chain privacy flag later.
Requires ownership.
```
dvcs set-private true
```

**`dvcs remote-info`** — print the configured rpc url / contract / account
/ repo id.

### Privacy: encryption

**`dvcs crypto-init <passphrase>`** — turn on AES-256-GCM encryption for
content pushed from now on.
```
dvcs crypto-init "a shared team passphrase"
```
What happens: a random 16-byte salt is generated locally, the key is
derived via PBKDF2 (200,000 iterations, SHA-256), and — if a repo is
already registered — the salt (not secret) gets published as its own tiny
on-chain blob under a deterministic id, so any collaborator running
`repo-connect`/`push`/`pull` auto-discovers it without being told
separately. **The passphrase itself never touches disk or the network.**
Every `push`/`pull` after this needs `--passphrase <p>` or the
`DVCS_PASSPHRASE` environment variable. A wrong passphrase fails loudly
(AES-GCM authentication failure), never silently.

### Identity: handles instead of raw addresses

Repo owners often don't know a collaborator's raw `0x...` address. The
identity registry lets an account claim a human-readable handle (an
email-shaped string is a natural choice, but any string works) so others
can refer to them by that instead.

**`dvcs identity-register <handle>`** — claim a handle for your configured
account. This is a transaction *from* that account, so the binding is
cryptographically signed by its own key — nobody else can claim a handle
"as" your address.
```
dvcs identity-register "alice@example.com"
```
**Important:** this proves *address ownership*, not *inbox ownership*.
Nothing verifies you actually control that email inbox — that would need an
off-chain verifier (send a code, prove receipt) bridging email to chain,
which is a different kind of system than a smart contract alone can be.
Treat a handle as a self-claimed nickname bound to a key — the same trust
level as a commit's author field.

**`dvcs identity-resolve <handle>`** — look up which address holds a
handle.
```
dvcs identity-resolve "alice@example.com"
# -> alice@example.com -> 0x1408dd7e408a6afa67054be5e1ae3525956a1fc9
```

**`dvcs identity-release`** — release your currently registered handle.

### Members and roles

**`dvcs member-add <address-or-handle> <role>`** — grant a role:
`none`, `reader`, `contributor`, or `maintainer`. Accepts a raw address
*or* a registered handle (resolved on-chain automatically). Requires
Maintainer role or ownership.
```
dvcs member-add "bob@example.com" contributor
```
Contributor can push commits/content and create branches/tags. Maintainer
can additionally force-push, delete branches, manage other collaborators,
and approve pull requests.

**`dvcs member-list`** — list everyone with an explicit role, plus the
owner, showing registered handles alongside addresses where available.
```
dvcs member-list
# 0x1408...1fc9  owner        (alice@example.com)
# 0xa668...9a08c3  contributor  (bob@example.com)
```

### Working locally: add, commit, status, branch, checkout

**`dvcs add <path> [<path>...]`** — stage files (recursively for
directories). Honors `.dvcsignore` in the repo root — same idea as
`.gitignore`: exact paths, `dir/` prefixes, and `*` wildcards.
```
echo -e "*.log\n.env" > .dvcsignore
dvcs add src README.md
```

**`dvcs status`** — current branch, its head, and staged files.

**`dvcs commit -m "<message>"`** — record a local commit from staged
files. Each commit tracks the **full** file tree (git's actual model, not
a diff) — unchanged files carry forward from the parent automatically.
Nothing is pushed on-chain yet.
```
dvcs commit -m "Initial commit"
```

**`dvcs branch [name]`** / **`dvcs branch -d <name>`** — list branches,
create one at HEAD, or delete one *locally* (never touches chain state; see
`delete-branch` for that).
```
dvcs branch feature-x
dvcs branch -d old-experiment
```

**`dvcs checkout <branch>`** — switch branches and restore that branch's
files into the working directory. Content not yet in your local object
store shows as "missing" — run `pull` first.

### Inspecting history

**`dvcs log [branch]`** — commit history (first-parent chain) from the
local cache.

**`dvcs ls [branch-or-commit]`** — list every tracked file at a commit
(like `git ls-tree --name-only`).
```
dvcs ls feature-x
```

**`dvcs show <branch-or-commit>`** — full commit metadata: author, date,
parent(s), tree root, message, file list.
```
dvcs show main
```

**`dvcs diff <ref-1> <ref-2>`** — which files were added/removed/modified
between two commits (path + hash level, not a line-by-line content diff).
```
dvcs diff main feature-x
# modified src/main.v
```

**`dvcs cat <branch-or-commit> <path>`** — print a tracked file's content
at a given commit without checking it out (like `git show <commit>:<path>`).
Requires the blob to already be in your local store.
```
dvcs cat main src/main.v
```

### Rewriting local history: rollback, rebase

**`dvcs rollback <commit-hash-or-prefix> [--hard]`** — move the current
branch's *local* pointer back to an earlier commit, git-`reset`-style.
Purely local; chain state is untouched. Without `--hard`, only the ref
moves; with it, tracked files are also restored (note: files added *after*
the rollback target are not deleted, unlike real `git reset --hard`).
```
dvcs rollback 4c7317c0 --hard
```
Since this moves the branch backwards, a following `push` needs `--force`.

**`dvcs rebase <onto-branch> [--ours | --theirs]`** — replay commits unique
to the current branch on top of another branch, purely locally. Finds the
common ancestor via first-parent walk, then re-creates each commit on top of
`<onto-branch>`'s current head.
```
dvcs checkout feature-old
dvcs rebase main
```
Each commit's own delta (what it changed relative to its *original* parent)
is 3-way-merged into the evolving target tree — see "Merge conflicts" below
for exactly how conflicts are detected and resolved. A following `push`
needs `--force` since replaying changes every commit's hash.

### Syncing with the chain: push, pull

**`dvcs push [branch] [--force] [--passphrase <p>]`** — push local-only
commits and their file content on-chain, then update the branch pointer.
```
dvcs push
dvcs push feature-x
dvcs push main --force
```
Every commit and every blob chunk is its own independently-confirmed
transaction (see "Resilience" below), and a private repo without
`crypto-init` will be refused here before anything is sent.

**`dvcs pull [branch] [--passphrase <p>]`** — sync commit metadata and file
content for a branch from chain into the local cache. Auto-discovers the
encryption salt if the repo uses one. Run `checkout` afterward to write
files into your working directory.
```
dvcs pull main
```

**`dvcs delete-branch <name>`** — delete a branch **on-chain**. Requires
Maintainer role or higher.

### Pull requests: review before merge

Git itself has no concept of a PR — this is a workflow the contract adds on
top of branches/commits, so merges into a protected branch require review.

**`dvcs pr-open <source-branch> <target-branch> "<title>" ["<description>"]`**
— propose merging one branch into another. Requires Contributor role;
both branches must already exist on-chain.
```
dvcs pr-open feature-x main "Add helper feature" "Small helper function"
```
The PR always merges whatever the source branch currently points to at
merge time, not a frozen snapshot — push more commits and an open PR
reflects them, GitHub-style.

**`dvcs pr-approve <pr-id>`** — approve. Requires Maintainer role or
ownership — genuine review authority, not just push access — and you
**cannot approve your own PR** (enforced on-chain, tested against both a
non-owner author and the repo owner acting as author).
```
dvcs pr-approve 0
```

**`dvcs pr-merge <pr-id>`** — merge once there are enough approvals
(default: 1, see below). Before sending anything on-chain, the CLI checks
locally whether this would actually be a fast-forward; if the target branch
has advanced independently since the PR's source diverged from it, it
refuses with the exact `rebase` + `push --force` steps to fix it (see
"Merge conflicts" below) rather than letting the transaction revert with a
generic error.
```
dvcs pr-merge 0
```

**`dvcs pr-close <pr-id>`** — close without merging. The author or a
Maintainer may do this.

**`dvcs pr-list`** / **`dvcs pr-show <pr-id>`** — list all PRs with status,
or show full detail on one.

**`dvcs pr-min-approvals <n>`** — set how many approvals a PR needs before
it can merge (defaults to 1 if never set). Requires Maintainer role.
```
dvcs pr-min-approvals 2
```

### Merge conflicts

This system has no textual, line-level diff/merge — files are content-
addressed blobs, either "the same" or "different." What it *does* have is a
proper **3-way merge at the file-tree level** (`merge3.v`), used identically
by both `rebase` and the PR-divergence check, so there's one conflict story
rather than two:

For every tracked path, given its hash at the common ancestor (`base`), on
your side (`ours`), and the other side (`theirs`):

| condition                        | result                          |
|-----------------------------------|----------------------------------|
| `ours == theirs`                  | agree — take it (covers both sides deleting the same path) |
| `base == ours` (you didn't change it) | take theirs |
| `base == theirs` (they didn't change it) | keep yours |
| all three differ                  | **conflict** |

This also correctly handles additions and deletions, not just edits — e.g.
one side deleting a path while the other modified it is a conflict
(modify/delete), and both sides adding the *same* new path with *different*
content is a conflict too.

**When `rebase` hits a conflict**, it stops at that commit (any commits
successfully replayed before it stay replayed) and reports every
conflicting path:
```
$ dvcs rebase main
CONFLICT: rebasing 0x7ac2c2e5... ("A's change") onto "main" hit
1 conflicting path(s) (both sides changed these since diverging):
  conflict.txt

Re-run with --ours (keep "branch-a"'s own version of conflicting paths) or
--theirs (take "main"'s version) to auto-resolve and continue, or
inspect both sides yourself with `dvcs cat <ref> <path>`.
```
Unlike git's own rebase — where "ours"/"theirs" confusingly flip meaning
compared to merge — this tool's `--ours`/`--theirs` always mean what they
sound like: `--ours` keeps *your current branch's* version, `--theirs`
takes *the other branch's* version, for every conflicting path in one pass.
There's no interactive per-hunk resolution; for anything more surgical,
inspect both sides with `dvcs cat <branch> <path>`, decide by hand, then
`add`/`commit` the result yourself.

**When `pr-merge` would need a real merge** (target diverged from source,
not just a fast-forward), it doesn't attempt one automatically — this
system has no way to create a merge commit through the PR flow without
bypassing the on-chain approval gate that's the entire point of a PR. It
refuses instead with the same fix `rebase` provides:
```
dvcs checkout feature-x
dvcs pull main
dvcs rebase main            # resolve any conflicts here, locally
dvcs push feature-x --force
dvcs pr-merge 0              # now a clean fast-forward
```

### Resilience and auditing

**`dvcs changelog`** — every on-chain action this CLI has taken from this
directory, in order, with its transaction hash. See below for why this
matters.
```
dvcs changelog
```

**`dvcs accounts`** — list accounts the configured RPC node exposes.

---

## Resilience: chunk limits + local changelog

A push can be interrupted at any point — dropped network, killed process,
a wrong passphrase discovered halfway through. Two things work together so
that never jeopardizes anything already confirmed:

- **Every commit and every blob chunk is its own independent transaction**,
  capped at `MAX_CHUNK_BYTES` (24 KiB) on-chain — enforced with a
  `ChunkTooLarge` revert, confirmed by testing a chunk one byte over the
  limit (rejected) and one exactly at it (accepted). Nothing is batched
  into one all-or-nothing transaction.
- **`blobAnnounced` / `commitExists`** let the CLI check, before sending
  anything, whether the contract already has a given commit or blob — so
  re-running `push` after an interruption skips everything already
  confirmed.
- **`.dvcs/changelog`** is the visible half of this: a local, append-only
  record of every on-chain action, with tx hashes, so after an interruption
  you can see exactly what landed before re-running `push`.
- **Automatic retry with backoff** in the RPC client itself for transient
  transport failures (e.g. a connection dropped under rapid sequential
  requests to a local dev node) — up to 3 attempts with exponential
  backoff, invisible in the common case, surfaced with a clear error only
  if every attempt fails.

---

## Testing

Two layers, both meant to actually be run, not just read:

**Unit tests** (`v test .` from `cli/`) — pure-logic tests alongside the
code they test (`*_test.v`), no chain required, run in a few seconds:
Keccak-256 against known vectors, ABI encode/decode round trips (including
one pinned against a live ethers.js reference), hex helpers, Merkle root
properties, `.dvcsignore` pattern matching, blob chunking/reassembly, and
every case of the 3-way merge logic (clean merges, both-sides-same-change,
add/add conflicts, modify/delete conflicts, deletion agreement).
```
cd cli && v -cc tcc test .
```

**Integration tests** (`test/integration/run.sh`) — a real end-to-end suite
that builds the CLI, compiles the contract, starts its own isolated
Hardhat node, deploys fresh, and drives the actual `dvcs` binary through
40+ assertions covering nearly everything in this README: private-repo
enforcement, identity registration and handle-based `member-add`, access
control, multi-user encrypted push/pull (including a second party who was
never told the salt directly), wrong-passphrase rejection, `diff`/`ls`/
`show`/`cat`, the full PR review lifecycle including self-approval blocks
and `pr-min-approvals` enforcement, `rebase` conflict detection and
`--theirs` resolution, `rollback`, the on-chain `MAX_CHUNK_BYTES`
enforcement, and the changelog. Safe to re-run — each run gets a fresh
chain and fresh temp directories, and cleans up its Hardhat node process on
exit.
```
cd test/integration
npm install --save-dev "hardhat@^2.22.0" ethers   # one-time
./run.sh
```
This suite is also how several real bugs described below were actually
found — including a transient RPC flakiness that a simple integration test
run surfaced immediately but would've been easy to miss testing by hand.

## What's been tested

Everything below was run against a real, freshly deployed contract on a
local Hardhat node during this project's own development — not just
compiled, actually exercised, including negative cases. Most of this is now
codified in the automated suites above, so it's re-checked on every run
rather than being a one-time claim:

- **Keccak-256** verified against known test vectors, including the
  ERC-20 `transfer(address,uint256)` selector.
- **ABI encoding** verified byte-for-byte identical to ethers.js's output.
- **`computeRepoId`** verified identical between the CLI's local
  computation and the contract's own.
- **Private repo enforcement**: pushing to a `--private` repo without
  `crypto-init` was refused client-side before any transaction was sent;
  after `crypto-init`, the push succeeded with encrypted content on-chain.
- **Identity + member-add by handle**: two accounts each registered a
  handle (`alice@example.com`, `bob@example.com`); the repo owner added the
  second as a Contributor using *only* the handle, never touching a raw
  address; `member-list` correctly displayed both handles.
- **Multi-user encrypted content, no IPFS**: a second, fully independent
  local repo — never told the encryption salt directly — ran
  `repo-connect`, auto-discovered the salt from chain, and `pull`ed with
  only the shared passphrase; content decrypted correctly and matched
  byte-for-byte.
- **Wrong passphrase rejected correctly**: AES-GCM authentication failure,
  not silent corruption; commit metadata still synced (always public) but
  content sync correctly stayed at zero.
- **On-chain chunk-size limit**: confirmed via direct contract calls that a
  chunk one byte over the limit reverts with `ChunkTooLarge` and one at the
  limit is accepted.
- **Full pull-request lifecycle**: opened a PR, confirmed the author
  (non-owner) could not approve their own PR, had the repo owner approve
  and merge it, then `pull`ed the target branch and confirmed the merged
  content was present and correctly decrypted.
- **Self-approval blocked for the repo owner too**: when the owner opened
  a second PR, their own approval attempt was also rejected, and the merge
  correctly failed with 0/2 required approvals — proving `pr-min-approvals`
  and the self-approval rule both hold regardless of who's asking.
- **`rebase` conflict detection**: constructed genuinely divergent history
  (two branches independently changing the same path from a common
  ancestor) and confirmed the CLI reported a real `CONFLICT` naming the
  path, rather than silently picking a winner; confirmed `--theirs`
  correctly auto-resolved and produced the expected content.
- **`diff`**, **`ls`**, **`show`**, **`cat`**: all verified against real
  local commit data, including `cat` printing exact decrypted file content.
- **Access control**: a user without a granted role was rejected pushing;
  granting Contributor immediately fixed it.
- **`.dvcsignore`**: verified excluding `*.log` and exact-name patterns.
- **`rollback`**: verified moving a branch pointer back by hash prefix and,
  with `--hard`, restoring files.
- **RPC retry logic**: after discovering an intermittent transport failure
  against a local dev node under rapid sequential requests, added
  retry-with-backoff to the RPC client and stress-tested it with 5
  back-to-back requests that previously triggered the failure — all clean.

## Known limitations

- **No real key management for transaction signing** — see "signing model"
  above; this CLI targets dev chains with unlocked accounts.
- **Handles prove address ownership, not inbox ownership** — see
  "Identity" above. Don't treat a registered handle as verified contact
  information.
- **Shared-passphrase encryption, not per-user keys.** Everyone reading
  encrypted content uses the *same* passphrase-derived key; there's no
  envelope encryption or per-collaborator key wrapping. Revoking one
  collaborator's read access to future content means rotating the
  passphrase for everyone.
- **`getFirstParentChain` only follows first-parents** — full merge-history
  reconstruction from chain alone isn't supported (a gas-cost tradeoff); a
  production indexer would replay events instead.
- **`rollback --hard` doesn't delete files added after the rollback
  target** — unlike real `git reset --hard`.
- **Merge conflict resolution is whole-file, not line-level** — `rebase`
  and PR-divergence handling detect and resolve conflicts per *path*
  (`--ours`/`--theirs` apply to every conflicting file at once), not
  per-hunk within a file. There's no interactive/textual merge editor;
  resolving a specific conflict by hand means inspecting both sides with
  `dvcs cat` and committing your own resolution.
- **PRs require both branches to already exist on-chain** before opening.
- **Every blob chunk is its own transaction** — pushing many/large files
  under the on-chain content mode means real gas cost on a live chain; for
  large binary assets, the CID-based off-chain mode may be cheaper.
