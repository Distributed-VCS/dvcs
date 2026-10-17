# VIDEO SCRIPT — recording a DVCS demo

Two ways to use this:

1. **Fully automated** (recommended): `./scripts/demo.sh` runs this entire
   script for you — starts its own chain, deploys fresh (no more "the
   address changed again" problem, since it captures and uses whatever it
   just deployed automatically), and executes every command below with
   realistic typed-out commands and timed pauses for narration. Just run
   it and talk over it. See "Using the automated script" at the end.
2. **Manual**, following this document scene-by-scene yourself in two
   terminals — more control over pacing and camera work, more setup.

Either way, every command below was verified working while writing this.

---

## Using the manual path

**Setup before you hit record** (not shown on camera):
- Follow SETUP.md through step 8. Have the contract address, and Alice's
  and Bob's addresses, in a text file ready to paste from.
- Two terminal windows, arranged side by side: **Alice** (left) and **Bob**
  (right). Increase font size for recording.
- A Hardhat node running in a third, minimized terminal.
- `cd` both Alice and Bob terminals into fresh empty directories.

Suggested on-screen labels: put a sticky note / terminal title "ALICE" and
"BOB" so viewers always know whose terminal they're looking at.

---



## Scene 1 — Cold open (0:00–0:30)

**SHOW:** Alice's terminal, empty prompt.

**SAY:**
> This is a version control system — like Git — but the history lives on
> a blockchain instead of a server. No GitHub, no central host. Let's push
> some real code to it.

No commands yet — just the empty terminal for a beat.

## Scene 2 — First repository (0:30–1:45)

**TYPE (Alice):**
```bash
dvcs init
dvcs remote http://127.0.0.1:8545 <contract-address> <alice-address>
dvcs repo-create acme-website
```
**SAY (while `repo-create` runs):**
> That's a real transaction — the repository's existence and ownership
> just got written on-chain. Let's add something to it.

**TYPE:**
```bash
echo "<h1>ACME Website</h1>" > index.html
dvcs add index.html
dvcs commit -m "Initial site structure"
dvcs push
```
**SAY (while `push` output scrolls):**
> Watch the output — that's not one transaction, it's several: the commit
> itself, the file content, and the branch pointer, each separately
> confirmed. If any one step failed here, nothing already confirmed would
> be lost.

**SHOW:** point at the three separate `tx:` hashes in the output.

## Scene 3 — Prove it's real (1:45–2:30)

**SAY:**
> I could just be printing believable-looking text. Let's check the actual
> blockchain state.

**TYPE:**
```bash
dvcs log
dvcs changelog
```
**SAY:**
> Every transaction, with its real hash, in order. This is the audit
> trail — not a claim, a receipt.

## Scene 4 — Meet Bob, added by email (2:30–4:00)

**SHOW:** switch to Bob's terminal.

**SAY:**
> Now let's bring in a collaborator. Normally you'd need Bob's wallet
> address to grant him access — which nobody wants to trade back and
> forth. Instead:

**TYPE (Bob):**
```bash
dvcs init
dvcs remote http://127.0.0.1:8545 <contract-address> <bob-address>
dvcs identity-register "bob@acme.example"
```
**SHOW:** switch back to Alice.

**TYPE (Alice):**
```bash
dvcs member-add "bob@acme.example" contributor
dvcs member-list
```
**SAY (as `member-list` prints):**
> Alice never touched Bob's raw address — just his handle. That handle is
> cryptographically bound to Bob's own key when he registered it, so it's
> not spoofable, but it's *not* verified email ownership either — worth
> being upfront about that.

## Scene 5 — Bob pulls with nothing but a name (4:00–5:00)

**SHOW:** Bob's terminal.

**TYPE (Bob):**
```bash
dvcs repo-connect <alice-address> acme-website
dvcs pull
dvcs checkout main
cat index.html
```
**SAY (as the file prints):**
> Bob just reconstructed Alice's exact file, byte for byte, from nothing
> but her address and a repo name. No git remote, no shared server —
> every byte of that came out of blockchain event logs.

## Scene 6 — Privacy, done honestly (5:00–6:30)

**SHOW:** a fresh terminal or scroll to clear space. Alice.

**SAY:**
> Here's something most "blockchain git" demos skip: a public blockchain
> can't actually hide data. Watch what happens with a private repo.

**TYPE (Alice):**
```bash
dvcs repo-create secret-notes --private
echo "sensitive plans" > notes.txt
dvcs add notes.txt
dvcs commit -m "notes"
dvcs push
```
**SAY (as it fails):**
> Refused. Marking a repo private doesn't magically hide it from a block
> explorer — nothing can, that's just how public chains work. So instead,
> this tool *requires* real encryption before it'll push anything to a
> private repo.

**TYPE:**
```bash
dvcs crypto-init "team-passphrase-2026"
export DVCS_PASSPHRASE="team-passphrase-2026"
dvcs push
```
**SAY:**
> Now it's actually encrypted — AES-256-GCM, before any of it ever leaves
> this machine. That passphrase never touches the chain in any form.

## Scene 7 — Pull requests that can't self-approve (6:30–8:00)

**SHOW:** back to the main `acme-website` repo, Alice.

**TYPE (Alice):**
```bash
dvcs branch feature-navbar
dvcs checkout feature-navbar
echo "<nav>Home | About</nav>" >> index.html
dvcs add index.html
dvcs commit -m "Add navigation"
dvcs push feature-navbar
```
**SHOW:** switch to Bob.

**TYPE (Bob):**
```bash
dvcs pr-open feature-navbar main "Add navigation" "small nav bar"
dvcs pr-approve 0
```
**SAY (as the approval fails):**
> Bob opened this PR, so he can't approve his own work — enforced by the
> smart contract itself, not just the CLI being polite. There's no way to
> route around this short of controlling a different private key.

**SHOW:** switch to Alice.

**TYPE (Alice):**
```bash
dvcs pr-approve 0
dvcs pr-merge 0
```
**SAY:**
> Alice reviews and merges. Real review gate, enforced on-chain.

## Scene 8 — A real conflict, handled honestly (8:00–9:15)

**SAY:**
> Last thing — what happens when two people change the same file
> differently?

**TYPE (Alice):**
```bash
dvcs checkout main
dvcs branch branch-a && dvcs branch branch-b
dvcs checkout branch-a
echo "Version A" > shared.txt && dvcs add shared.txt && dvcs commit -m "A"
dvcs checkout branch-b
echo "Version B" > shared.txt && dvcs add shared.txt && dvcs commit -m "B"
dvcs checkout branch-a
dvcs rebase branch-b
```
**SAY (as CONFLICT prints):**
> It stops and tells you exactly what conflicts — it doesn't silently pick
> a winner. You resolve it explicitly.

**TYPE:**
```bash
dvcs rebase branch-b --theirs
```
**SAY:**
> Resolved, and the resolution is a plain, ordinary flag — not a hidden
> guess.

## Scene 9 — Wrap (9:15–10:00)

**SHOW:** either terminal, `dvcs help` output.

**SAY:**
> That's branches, encrypted private repos, identity without exposing
> addresses, reviewed pull requests, and real conflict handling — all
> backed by an actual smart contract, all inspectable on-chain. Setup
> guide and full tutorial are in the repo if you want to try it yourself.

**End on:** `dvcs help` scrolling, or the project README.

---

## Using the automated script

`scripts/demo.sh` runs the entire scene sequence above for you — same
narrative, same commands, same two users (Alice and Bob, simulated by
`cd`-ing between two directories rather than two terminal windows), but
fully hands-off:

```bash
cd scripts
npm install --save-dev "hardhat@^2.22.0" ethers   # one-time, if not already done
./demo.sh
```

It starts its own Hardhat node, deploys fresh, and captures the resulting
contract and account addresses into shell variables it uses for every
subsequent command — you never see or need to copy an address, which is
exactly the problem ("I always get a new hash") this script exists to
solve. Each command is "typed" out on screen at a readable pace before
running for real, and it pauses at scene boundaries and after narration
lines so you have time to talk over it.

**Options** (see also the comment header in `demo.sh`):
```bash
./demo.sh --pause 8              # linger longer at each scene banner (default: 6s)
./demo.sh --type-speed 0.03      # type more slowly (default: 0.02s/char; 0 = instant)
./demo.sh --no-color             # if your recording terminal doesn't render ANSI well
./demo.sh --keep-running         # leave the chain up afterward so you can keep exploring live
./demo.sh --port 8556            # use a different port (default: 8555)
```

It's safe to run more than once in a row — each run tears down and
recreates its own chain and its own `demo-workspace/` directory, so a
practice run followed immediately by the real recording take behaves
identically both times. If you want to rehearse the pacing without
actually recording, run it once with `--pause 2 --type-speed 0` first to
see the whole flow quickly, then again at real speed when you're ready.

---

## Notes for editing

- The slowest real-world waits are `push`/`pr-merge`/`pr-approve` — each
  is a transaction, so there's a beat while it confirms. Consider speeding
  these segments up in post rather than cutting the wait entirely, so
  viewers register that something real is happening.
- If a scene's `pr-approve`/`pr-merge` id isn't `0` in your run (e.g. you
  practiced first and left old PRs around), check `dvcs pr-list` before
  recording and adjust the id in that scene's commands.
- Consider a lower-third or on-screen tx hash callout during Scene 3 and
  Scene 9 — verifying a hash on a block explorer (if you're on a public
  testnet rather than a local Hardhat node) is a strong "this is real"
  beat if you have time to include it.
