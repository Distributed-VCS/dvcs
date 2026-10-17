# SETUP — from a completely bare machine to a running DVCS repository

This assumes **nothing** is installed yet. Every tool below is named with
where to get it. Commands shown are for Debian/Ubuntu Linux; macOS notes
(via [Homebrew](https://brew.sh)) are called out where the steps differ.
Windows: use [WSL2](https://learn.microsoft.com/windows/wsl/install) and
follow the Linux steps inside it.

**On Windows and would rather not set up WSL2 yourself?** See
**`DOCKER.md`** instead — install Docker Desktop (which manages a Linux
environment for you automatically) and everything below happens inside a
container with one or two commands. This guide is for a native install on
any OS, including doing WSL2 setup yourself on Windows.

Total tools you'll end up installing: **V** (compiles the CLI), **Node.js**
(runs the Solidity compiler and [Hardhat](https://hardhat.org), a local
test blockchain), and **Python 3** (used only by the build scripts to
shuffle JSON around — most systems already have this).

We recommend putting both `v` and `dvcs` on your `PATH` as you go (steps 3
and 6 below do this by default) — the whole guide and tutorial assume you
can just type `v` and `dvcs` from anywhere, which is a lot more pleasant
than typing full paths every time.

---

## 1. Install Python 3 (build-script dependency only)

Most Linux distros and macOS ship this already. Check:
```bash
python3 --version
```
If missing:
```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y python3

# macOS
brew install python3
```

## 2. Install Node.js + npm

Needed for: the Solidity compiler (`solc`/`solcjs`), a local test
blockchain ([Hardhat](https://hardhat.org)), and the deploy script. Any
reasonably recent Node (18+) works.

```bash
# Debian/Ubuntu -- via NodeSource (the distro's own repo is often too old)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# macOS
brew install node
```
Check it worked:
```bash
node --version   # v18.x or newer
npm --version
```

## 3. Install the V compiler

V has no package-manager install on most systems — you build it from its
own source, which is quick (V compiles itself in seconds).

```bash
# Prerequisite: a C compiler. Debian/Ubuntu:
sudo apt-get install -y git build-essential
# macOS: install Xcode Command Line Tools if you haven't already:
xcode-select --install

# Get and build V itself
git clone --depth 1 https://github.com/vlang/v.git
cd v
make
```
This produces a `v` binary inside that `v/` directory. Put it on `PATH`
now, so plain `v` works everywhere from here on:
```bash
echo 'export PATH="$PATH:'"$(pwd)"'"' >> ~/.bashrc   # or ~/.zshrc on macOS/zsh
source ~/.bashrc
v version   # should print a version with no ./ needed
```
`cd` back out of the `v/` directory before continuing.

**Also install `tcc`** (a small, very fast C backend V is designed to pair
with):
```bash
sudo apt-get install -y tcc     # Debian/Ubuntu
brew install tcc                # macOS
```
Every `v` build command in this guide and in the project's own scripts
uses `-cc tcc` for this reason: as of recent V builds, the default backend
(plain system `cc`/`gcc`) can trigger a slow, memory-heavy internal
compiler self-check on a project this size, that `-cc tcc` avoids
entirely — see "Why `-cc tcc`?" in the Troubleshooting section if you're
curious, or if you skip installing `tcc` and a build hangs or gets killed.

## 4. Get the DVCS project itself

Unzip/copy the project wherever you want to work from, e.g.:
```bash
cd ~
unzip dvcs-project.zip
cd dvcs-project
```
You should see `contracts/`, `cli/`, `scripts/`, `test/`, `build/`,
`README.md`, and this file.

## 5. Compile the contract

```bash
./scripts/compile-contract.sh
```
This wraps `solcjs` (fetched automatically via `npx` the first time you
run it — no separate install needed) with the exact settings this contract
needs (`viaIR` to avoid a stack-too-deep error from its PR functions,
`evmVersion: paris` for compatibility with local dev chains). It writes
`build/DVCS.bin` and `build/DVCS.abi`. You should see:
```
OK: build/DVCS.bin (28944 hex chars), build/DVCS.abi (80 entries)
```

## 6. Build the CLI and put it on PATH

```bash
cd cli
v -cc tcc -o dvcs .
cd ..
```
This produces a single binary at `cli/dvcs`. Should complete in a couple
of seconds with no output (V is quiet on success).

**Put it on PATH** (recommended — the rest of this guide and the tutorial
assume you can just type `dvcs`):
```bash
echo 'export PATH="$PATH:'"$(pwd)/cli"'"' >> ~/.bashrc
source ~/.bashrc
dvcs help   # should print the command list with no ./ or full path needed
```
(If you'd rather not touch your shell config, `./cli/dvcs help` from the
project root works identically with zero setup — PATH only changes how you
type the command, nothing else. A symlink into somewhere already on PATH,
e.g. `sudo ln -s "$(pwd)/cli/dvcs" /usr/local/bin/dvcs`, is a third option.
The rest of this guide uses the plain `dvcs` form.)

## 7. Start a local blockchain to develop against

You need *some* Ethereum-compatible node with unlocked accounts (see
README "Signing model" for why). This project is developed and tested
against **Hardhat's** local node (Hardhat 2, specifically — Hardhat 3
changed significantly and needs a different project layout than what's
shown here).

```bash
cd scripts
npm install --save-dev "hardhat@^2.22.0" ethers   # one-time; ethers is used by deploy.js next
npx hardhat node
```
Leave this running in its own terminal. It prints 20 pre-funded,
already-unlocked accounts — you'll use the first one. A config file,
`scripts/hardhat.config.js`, is already included; Hardhat needs one to
start even though we don't use Hardhat's own compile/test/deploy tooling
(the contract is compiled by `solc` directly in step 5, and deployed by a
plain `ethers.js` script in step 8).

**Gotcha to know about**: Hardhat must be run from *inside* the directory
containing its `node_modules` and config file — `cd scripts` above isn't
optional. Running `npx hardhat` from anywhere else fails with `HH12:
Trying to use a non-local installation`.

## 8. Deploy the contract

In a **new terminal** (leave the Hardhat node running in the other one):
```bash
cd dvcs-project/scripts
node deploy.js
```
Output looks like:
```
Deploying to http://127.0.0.1:8545 from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 ...

Deployed.
  contract: 0x5FbDB2315678afecb367f032d93F642f64180aa
  accounts: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, 0x70997970C51812dc3A010C7d01b50e0d17dc79C8, ...

Next step:
  dvcs remote http://127.0.0.1:8545 0x5FbDB2315678afecb367f032d93F642f64180aa 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```
(Hardhat's first two accounts are always the same well-known addresses
shown above, unlike some other dev chains that randomize them — handy for
following a written guide exactly.) Copy that last line — you'll run it
next.

## 9. Your first repository

```bash
mkdir ~/my-first-dvcs-repo && cd ~/my-first-dvcs-repo
dvcs init
dvcs remote <rpc-url> <contract-address> <account-address>   # from step 8
dvcs repo-create myproject
echo "hello" > README.md
dvcs add README.md
dvcs commit -m "Initial commit"
dvcs push
```
If `push` succeeds, you're fully set up. Continue to **TUTORIAL.md** for a
guided walkthrough of everything else (branches, encryption, pull
requests, identity handles, rebase, and so on) — or see the main
`README.md`'s "Command reference" section, and `dvcs help <command>` for
any command's built-in reference.

---

## 10. Running the test suites

**Unit tests** (fast, no blockchain needed):
```bash
cd dvcs-project/cli
v -cc tcc test .
```
Expect ~10 files, ~20-30 seconds total (one file deliberately runs a real
production-strength PBKDF2 pass, which dominates that time).

**Integration tests** (spins up its own isolated Hardhat node, deploys
fresh, drives the real CLI through 40+ assertions):
```bash
cd dvcs-project/test/integration
npm install --save-dev "hardhat@^2.22.0" ethers   # one-time, separate from scripts/'s install
./run.sh
```
This does **not** need your step-7 Hardhat node running — it starts and
stops its own on a different port and cleans up after itself. Safe to
re-run any time.

---

## Troubleshooting

**Why `-cc tcc`?** As of recent V compiler builds, plain `v -o dvcs .`
(using the default system `cc`/`gcc` backend) can trigger an internal,
experimental compiler self-validation pass on a project this size that is
extremely slow and memory-heavy — on a constrained machine it can hang for
minutes or get killed by the OS for using too much memory, even though
nothing is actually wrong with the code (confirmed while building this
project: identical source compiled in seconds with `tcc` and never
completed with plain `cc` in a memory-constrained test). `-cc tcc` uses
V's own preferred, much lighter C backend instead and sidesteps this
entirely. If you forget the flag and a build seems stuck or your system
starts swapping heavily, that's very likely why — install `tcc` (see
step 3) and add `-cc tcc` to the command.

**`v: command not found`** — V isn't on PATH; either use `/path/to/v/v`
directly or complete the PATH step in section 3.

**`dvcs: command not found`** — same idea; either use `./cli/dvcs` from the
project root, or complete the PATH step in section 6.

**`solcjs: command not found` / compile script hangs on first run** — the
compile script shells out to `npx -p solc solcjs`, which downloads solc the very
first time; this needs network access and can take a minute. Subsequent
runs are fast (cached).

**`HH12: Trying to use a non-local installation of Hardhat`** — you ran
`npx hardhat ...` from somewhere other than the directory it was installed
in (`scripts/`, or `test/integration/` for the test suite). `cd` there
first.

**`Hardhat only supports ESM projects` / `"type": "module"`** — you (or a
copy-pasted command) installed plain `hardhat` without a version pin and
got Hardhat 3, which needs a different, ESM-based project layout than this
guide uses. Reinstall pinned to 2.x: `npm install --save-dev
"hardhat@^2.22.0"`.

**`dvcs push` fails with "gas estimation failed"** — usually means the
transaction would revert for a real reason (wrong role, repo doesn't
exist, private repo without `crypto-init`, etc.) — read the message that
follows it; the CLI surfaces the underlying revert reason.

**`dvcs push`/`pull` fails with "RPC transport error"** — the CLI retries
transient network failures automatically (3 attempts with backoff); if you
still see this, check your dev chain (step 7) is actually running and the
`rpc-url` in `dvcs remote` matches its address/port.

**Hardhat node exits or hangs on startup** — make sure nothing else is
already using port 8545 (`lsof -i :8545` on Linux/macOS); pick a different
port with `npx hardhat node --port <n>`, and use the matching URL in
`dvcs remote` and when running `deploy.js <rpc-url>`.

**Contract redeploys change the address** — every time you restart your
dev chain and re-run `deploy.js`, you get a fresh contract at a new
address with no data in it (dev chains don't persist state across
restarts by default). Re-run `dvcs remote` with the new address, and
you'll need to `repo-create` again — this is a dev-chain quirk, not a bug.
