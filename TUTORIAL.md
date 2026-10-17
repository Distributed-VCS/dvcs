# TUTORIAL — learn DVCS by building a small site with a collaborator

This is a hands-on walkthrough, not a reference (see `README.md`'s
"Command reference" for that, or `dvcs help <command>` any time). Every
command below was actually run while writing this file, against a real
local chain — the output shown is real output, not illustrative.

**Before starting:** finish `SETUP.md` through step 8 (a Hardhat node
running, the contract deployed, `dvcs` on your PATH). You'll play two
people in this tutorial — Alice, who owns the project, and Bob, a
collaborator — so open two terminals. Where a command needs an address,
substitute your own from `dvcs remote`'s output in SETUP.md step 8.

---

## Part 1 — Alice starts a project

In terminal 1:
```bash
mkdir ~/tutorial-alice && cd ~/tutorial-alice
dvcs init
dvcs remote http://127.0.0.1:8545 <contract-address> <alice-address>
dvcs repo-create acme-website
```
```
Initialized empty dvcs repository in .../tutorial-alice/.dvcs
Configured remote:
  rpc_url  = http://127.0.0.1:8545
  contract = 0x5FbDB2315678afecb367f032d93F642f64180aa
  account  = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Submitting createRepository("acme-website", false) ...
  tx: 0x8b6b0c19...
Repository created.
  repo_id = 0x30a9d576...
```
That last transaction registered the repository on-chain — it now
publicly exists, owned by Alice's address, before a single file has been
added. This is the core idea: existence, ownership, and history are chain
facts, not something a server decides to show you.

Add some files and make your first commit:
```bash
echo "<h1>ACME Website</h1>" > index.html
mkdir css && echo "body { margin: 0; }" > css/style.css
dvcs add index.html css
dvcs commit -m "Initial site structure"
dvcs push
```
```
Staged 2 file(s).
[main 0b1c3ce7] Initial site structure
  2 file(s) changed, 2 tracked total, tree root 0x2fdd9455...
Pushing 1 commit(s) to branch "main"...
  pushed 0x0b1c3ce7...  (tx 0x1685bf5f...)
  content: 2 tracked file(s), 2 uploaded this push
Branch "main" now points to 0x0b1c3ce7... on-chain (tx 0x6c6341bd...).
```
Three separate things just happened, each its own transaction: the commit
was registered, both files' content was uploaded as chunked event logs,
and the `main` branch pointer moved to the new commit. `dvcs log` shows
what you'd expect:
```bash
dvcs log
```
```
commit 0x0b1c3ce7209828fa310f966e3063cc383083b781f16d3e6acfd74bc7eea916f6
Author: 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
Date:   2026-08-19 09:28:37

    Initial site structure
```

## Part 2 — branching, and inspecting history without checking it out

```bash
dvcs branch feature-navbar
dvcs checkout feature-navbar
echo "<nav>Home | About | Contact</nav>" >> index.html
dvcs add index.html
dvcs commit -m "Add navigation bar"
```
Now compare the two branches **without switching to either**:
```bash
dvcs diff main feature-navbar
```
```
modified index.html
```
Look at exactly what changed, and what's tracked, without touching your
working directory:
```bash
dvcs show feature-navbar
dvcs cat feature-navbar index.html
```
```
commit 0x6fcb2cca...
Author: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Date:   2026-08-19 09:28:40
Parent: 0x0b1c3ce7...
Tree:   0xddc3c817...

    Add navigation bar

2 file(s):
  c1e5c590  css/style.css
  ea5b6aaf  index.html
<h1>ACME Website</h1>
<nav>Home | About | Contact</nav>
```
`ls`, `show`, `diff`, and `cat` all read from your local commit cache, so
they're instant and free — no transaction, not even a read call, once a
commit is cached.

## Part 3 — Alice registers a handle, and adds Bob by email instead of address

Nobody wants to trade raw `0x...` addresses to collaborate. Register a
handle:
```bash
dvcs identity-register "alice@acme.example"
```
```
Registered handle "alice@acme.example" for 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (tx 0xc02d1c7a...).
This proves you control this address -- it does not verify you own any
email inbox this string might resemble. Anyone can now use `dvcs member-add
alice@acme.example <role>` on a repo instead of your raw address.
```
That disclaimer is important and worth re-reading: this is a
self-sovereign claim, cryptographically bound to Alice's key, not
verified email ownership — see README "Identity" for the full reasoning.

In **terminal 2**, playing Bob:
```bash
mkdir ~/tutorial-bob && cd ~/tutorial-bob
dvcs init
dvcs remote http://127.0.0.1:8545 <contract-address> <bob-address>
dvcs identity-register "bob@acme.example"
```

Back in terminal 1, Alice grants Bob a role **by his handle**, never
touching his address:
```bash
dvcs member-add "bob@acme.example" contributor
dvcs member-list
```
```
Set bob@acme.example (0x70997970c51812dc3a010c7d01b50e0d17dc79c8) to role "contributor" (tx 0x2f4effa1...).
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266  owner        (alice@acme.example)
0x70997970c51812dc3a010c7d01b50e0d17dc79c8  contributor  (bob@acme.example)
```
Push the feature branch so Bob has something to work with:
```bash
dvcs push feature-navbar
```

## Part 4 — Bob's side: connect, pull, and open a pull request

In terminal 2:
```bash
dvcs repo-connect <alice-address> acme-website
dvcs pull
dvcs checkout main
```
```
Connected to on-chain repository.
  repo_id       = 0x30a9d576...
  owner         = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  commit_count  = 2
Synced 1 new commit(s) and 2 file blob(s) for branch "main".
...
Switched to branch "main" at 0x0b1c3ce7...
  restored 2 file(s)
```
Bob now has Alice's files, fetched entirely through chain data — no
shared filesystem, no server either of them runs. Bob didn't even need to
`pull feature-navbar` specifically to reference it — branch *names* are
public on-chain, so he can open a PR against it directly:
```bash
dvcs pr-open feature-navbar main "Add navigation bar" "Adds a simple nav bar to the homepage"
```
```
Opened pull request: feature-navbar -> main
  "Add navigation bar"
  tx: 0x18c5a461...
Run `dvcs pr-list` to find its id.
```
Now — since Bob authored this PR — try approving it himself:
```bash
dvcs pr-approve 0
```
```
error: gas estimation failed (the transaction would likely revert): ...
```
Correctly refused. Self-approval is blocked **on-chain**, not just by CLI
convention — nothing about how you call the contract directly can get
around it.

## Part 5 — Alice reviews and merges

Back in terminal 1:
```bash
dvcs pr-list
dvcs pr-show 0
dvcs pr-approve 0
dvcs pr-merge 0
```
```
#0  [open]  feature-navbar -> main  "Add navigation bar"  (0 approval(s))
...
Approved PR #0 (tx 0xbcda82e8...).
Merged PR #0 (tx 0xee62a1df...).
```
Pull the result and see Bob's change land on `main`:
```bash
dvcs pull main
dvcs checkout main
cat index.html
```
```
<h1>ACME Website</h1>
<nav>Home | About | Contact</nav>
```

## Part 6 — undo something: rollback

Say that nav bar needs rethinking. Move `main` back, locally:
```bash
dvcs rollback 0b1c3ce7
```
```
Rolled back branch "main" to 0x0b1c3ce7... (working tree left untouched; use --hard to also restore files).
Note: this only changed your local branch pointer. To make the on-chain
branch match, run `dvcs push --force`...
```
Nothing on-chain changed yet — `rollback` is local-only, like `git reset`.
Add `--hard` to also restore the working directory to match, and
`push --force` when you're ready to actually move the on-chain branch
backward (a plain `push` is refused here on purpose — see README "Merge
conflicts" for why fast-forward protection matters).

## Part 7 — a real conflict, and resolving it

Two branches changing the same file differently is where things get
interesting. From `main`:
```bash
dvcs branch branch-a && dvcs branch branch-b

dvcs checkout branch-a
echo "Version A" > shared.txt
dvcs add shared.txt && dvcs commit -m "A's change"

dvcs checkout branch-b
echo "Version B" > shared.txt
dvcs add shared.txt && dvcs commit -m "B's change"

dvcs checkout branch-a
dvcs rebase branch-b
```
```
CONFLICT: rebasing 0x... ("A's change") onto "branch-b" hit
1 conflicting path(s) (both sides changed these since diverging):
  shared.txt

Re-run with --ours (keep "branch-a"'s own version of conflicting paths) or
--theirs (take "branch-b"'s version) to auto-resolve and continue, or
inspect both sides yourself with `dvcs cat <ref> <path>`.
```
It stopped rather than silently picking a winner. Inspect both sides, then
resolve:
```bash
dvcs cat branch-a shared.txt   # Version A
dvcs cat branch-b shared.txt   # Version B
dvcs rebase branch-b --theirs   # take branch-b's version for every conflict
```
See README "Merge conflicts" for exactly how the 3-way merge decides
what's a real conflict vs. an automatic resolution, and how PR merges use
the same logic for divergent branches.

## Part 8 — privacy: encryption for real confidentiality

Access-control roles decide who can *write*. They don't hide anything from
someone reading the chain directly — a private repo without encryption is
still fully readable by anyone with a block explorer. Here's the actual
privacy mechanism:
```bash
mkdir ~/tutorial-private && cd ~/tutorial-private
dvcs init
dvcs remote http://127.0.0.1:8545 <contract-address> <alice-address>
dvcs repo-create secret-notes --private
mkdir notes && echo "The launch code is 1234" > notes/launch.txt
dvcs add notes
dvcs commit -m "sensitive notes"
dvcs push
```
```
error: this repository is marked private but encryption is not enabled;
run `dvcs crypto-init <passphrase>` before pushing content ...
```
Refused before a single byte left the machine. Turn on encryption and
retry:
```bash
dvcs crypto-init "launch-team-2026"
export DVCS_PASSPHRASE="launch-team-2026"
dvcs push
```
```
Encryption enabled for this repository.
...
Salt published on-chain (not secret) so `repo-connect` auto-discovers it.
Pushing 1 commit(s) to branch "main"...
  pushed 0x7b162cc2...  (tx 0x32676a74...)
  content: 1 tracked file(s), 1 uploaded this push (encrypted)
```
A collaborator who's never been told the salt directly can still discover
it automatically (it's not secret — only the passphrase is) and, given the
passphrase through some out-of-band channel, decrypt everything with
ordinary `pull`. See README "Encryption" for exactly what is and isn't
protected by this.

## Part 9 — the audit trail

Every transaction any of this produced is recorded locally, in order, with
its hash:
```bash
cd ~/tutorial-alice
dvcs changelog
```
```
2026-08-19 09:28:37  repo-create       name="acme-website" private=false
                     tx: 0x8b6b0c19...
2026-08-19 09:28:37  push-commit       commit=0x0b1c3ce7... branch=main
                     tx: 0x1685bf5f...
...
2026-08-19 09:29:02  pr-merge          pr_id=0
                     tx: 0xee62a1df...
```
This is what makes an interrupted `push` recoverable — every commit and
every blob chunk is its own confirmed transaction, so re-running `push`
after a failure skips everything already on-chain instead of starting
over. See README "Resilience" for the full story.

---

## Where to go next

- `dvcs help` / `dvcs help <command>` — built-in reference for every
  command, including several not covered in this walkthrough
  (`delete-branch`, `pr-min-approvals`, `set-private`).
- `README.md` "Command reference" — the same ground as this tutorial, but
  organized as reference documentation rather than a narrative.
- `README.md` "Known limitations" — worth reading before you rely on this
  for anything real; it's honest about what this system does and doesn't
  guarantee.
