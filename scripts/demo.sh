#!/usr/bin/env bash
# Automated demo runner for recording tutorial videos.
#
# Solves the "the contract address is different every time" problem: this
# script starts its own Hardhat node, deploys fresh, captures the resulting
# addresses into shell variables, and uses them for every command itself --
# you never need to copy-paste an address. Just run it and talk over it.
#
# Usage:
#   cd scripts
#   npm install --save-dev "hardhat@^2.22.0" ethers   # one-time, if not already done
#   ./demo.sh
#
# Options:
#   --pause N        seconds to pause at each scene banner for narration (default: 6)
#   --type-speed N   seconds per character when "typing" commands (default: 0.02; 0 = instant)
#   --no-color       disable ANSI colors (if your recording terminal doesn't render them well)
#   --keep-running   don't stop the Hardhat node when the demo finishes (so you can keep exploring)
#   --port N         port for the demo's own Hardhat node (default: 8555, to avoid clashing
#                     with a node you might already have running on 8545)
#
# Safe to re-run: uses its own isolated Hardhat node and resets its own
# demo-workspace/ directory each time.

set -uo pipefail
[ -d "/home/claude/v" ] && export PATH="$PATH:/home/claude/v"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DVCS="${PROJECT_ROOT}/cli/dvcs"
SAMPLE_V1="${PROJECT_ROOT}/examples/task-tracker/v1"
SAMPLE_V2="${PROJECT_ROOT}/examples/task-tracker/v2-navdark-feature"
WORKSPACE="${SCRIPT_DIR}/demo-workspace"
ALICE_DIR="${WORKSPACE}/alice"
BOB_DIR="${WORKSPACE}/bob"
PRIVATE_DIR="${WORKSPACE}/alice-private"

PAUSE=6
TYPE_SPEED=0.02
USE_COLOR=1
KEEP_RUNNING=0
PORT=8555

while [ $# -gt 0 ]; do
	case "$1" in
	--pause) PAUSE="$2"; shift 2 ;;
	--type-speed) TYPE_SPEED="$2"; shift 2 ;;
	--no-color) USE_COLOR=0; shift ;;
	--keep-running) KEEP_RUNNING=1; shift ;;
	--port) PORT="$2"; shift 2 ;;
	*) echo "unknown option: $1"; exit 1 ;;
	esac
done
RPC_URL="http://127.0.0.1:${PORT}"

if [ "$USE_COLOR" = "1" ]; then
	C_BANNER='\033[1;36m'  # bold cyan
	C_SAY='\033[0;33m'     # yellow
	C_CMD='\033[1;32m'     # bold green
	C_TREE='\033[0;35m'    # magenta -- file trees and commit chains
	C_STATUS='\033[1;34m'  # bold blue -- status panels
	C_RESET='\033[0m'
else
	C_BANNER=''; C_SAY=''; C_CMD=''; C_TREE=''; C_STATUS=''; C_RESET=''
fi

# ---------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------

banner() {
	local text="$1"
	local width=$((${#text} + 4))
	local border
	border=$(printf '─%.0s' $(seq 1 "$width"))
	echo ""
	echo ""
	printf "${C_BANNER}┌%s┐${C_RESET}\n" "$border"
	printf "${C_BANNER}│  %s  │${C_RESET}\n" "$text"
	printf "${C_BANNER}└%s┘${C_RESET}\n" "$border"
	echo ""
	sleep "$PAUSE"
}

say() {
	echo ""
	printf "${C_SAY}▸ %s${C_RESET}\n" "$1"
	echo ""
	sleep "$(awk -v p="$PAUSE" 'BEGIN{print p/2}')"
}

# type_out prints a string as if it were being typed live, then a newline.
type_out() {
	local text="$1"
	if [ "$(awk -v t="$TYPE_SPEED" 'BEGIN{print (t==0)?1:0}')" = "1" ]; then
		printf '%s\n' "$text"
		return
	fi
	local i char
	for ((i = 0; i < ${#text}; i++)); do
		char="${text:$i:1}"
		printf '%s' "$char"
		sleep "$TYPE_SPEED"
	done
	printf '\n'
}

# run "<full shell command as one string>" -- types it out, then executes
# it for real. Uses eval deliberately: every call site below is a fixed
# string written into this script, never external/user input.
run() {
	printf "${C_CMD}\$ ${C_RESET}"
	type_out "$1"
	eval "$1"
	echo ""
}

# run_expect_fail is identical but for commands the demo deliberately shows
# failing (self-approval, private-repo-without-encryption) -- keeps that
# visually distinct so it doesn't look like a mistake during recording.
run_expect_fail() {
	printf "${C_CMD}\$ ${C_RESET}"
	type_out "$1"
	if eval "$1"; then
		echo "(unexpected: this command was supposed to fail)"
	else
		printf "${C_SAY}▸ (failed as expected -- that's the point of this step)${C_RESET}\n"
	fi
	echo ""
}

# ---------------------------------------------------------------------
# Visualizations: a file tree, a linear commit-chain diagram, and a
# compact status panel -- so the actual structure being built is visible
# at a glance, not just buried in raw command output.
# ---------------------------------------------------------------------

# tree_view <directory> [label] -- renders the tracked working directory
# as an indented tree (no external `tree` binary required).
tree_view() {
	local root="$1"
	local label="${2:-$(basename "$root")}"
	local tmpfile
	tmpfile=$(mktemp)
	(cd "$root" && find . -mindepth 1 -not -path '*/.dvcs*' -not -name '.dvcs' 2>/dev/null | sed 's|^\./||' | sort) > "$tmpfile"
	local total
	total=$(wc -l < "$tmpfile" | tr -d ' ')

	printf "${C_TREE}%s/${C_RESET}\n" "$label"
	local i=0
	while IFS= read -r path; do
		i=$((i + 1))
		local depth name is_last next next_depth indent d
		depth=$(grep -o "/" <<<"$path" | wc -l | tr -d ' ')
		name="${path##*/}"
		is_last=1
		if [ "$i" -lt "$total" ]; then
			next=$(sed -n "$((i + 1))p" "$tmpfile")
			next_depth=$(grep -o "/" <<<"$next" | wc -l | tr -d ' ')
			[ "$next_depth" -ge "$depth" ] && is_last=0
		fi
		indent=""
		d=0
		while [ "$d" -lt "$depth" ]; do
			indent="${indent}│   "
			d=$((d + 1))
		done
		if [ "$is_last" -eq 1 ]; then
			printf "${C_TREE}%s└── %s${C_RESET}\n" "$indent" "$name"
		else
			printf "${C_TREE}%s├── %s${C_RESET}\n" "$indent" "$name"
		fi
	done <"$tmpfile"
	rm -f "$tmpfile"
	echo ""
}

# commit_chain <branch> -- renders that branch's history (oldest to
# newest) as a linear chain of nodes, parsed from `dvcs log`.
commit_chain() {
	local branch="$1"
	local pairs
	pairs=$("$DVCS" log "$branch" 2>/dev/null | awk '
		/^commit / { hash=$2; getmsg=0; next }
		/^$/ { getmsg=1; next }
		getmsg==1 && NF>0 { msg=$0; sub(/^    /,"",msg); print hash "|" msg; getmsg=0 }
	')
	if [ -z "$pairs" ]; then
		printf "${C_TREE}(%s: no commits yet)${C_RESET}\n\n" "$branch"
		return
	fi
	local rendered=()
	while IFS= read -r line; do
		rendered=("$line" "${rendered[@]}")
	done <<<"$pairs"

	local out="" first=1 hash short msg
	for line in "${rendered[@]}"; do
		hash="${line%%|*}"
		msg="${line#*|}"
		short="${hash:2:8}"
		if [ "$first" -eq 1 ]; then
			out="●  ${short}  \"${msg}\""
			first=0
		else
			out="${out}   ──▶   ●  ${short}  \"${msg}\""
		fi
	done
	printf "${C_TREE}%s${C_RESET}\n" "$out"
	printf "${C_TREE}   (%s)${C_RESET}\n\n" "$branch"
}

# status_line <who> -- a compact one-glance panel: user, branch, HEAD,
# tracked file count. Deliberately borderless (no fixed-width box to keep
# aligned against variable-length dynamic content).
status_line() {
	local who="$1"
	local branch head files
	branch=$("$DVCS" status 2>/dev/null | head -1 | sed 's/On branch //')
	head=$("$DVCS" status 2>/dev/null | grep "^HEAD:" | awk '{print substr($2,3,8)}')
	files=$("$DVCS" ls 2>/dev/null | grep -c .)
	[ -z "$head" ] && head="(none yet)"
	printf "${C_STATUS}┃ %-8s  branch: %-16s  HEAD: %-10s  files: %s${C_RESET}\n\n" \
		"$who" "$branch" "$head" "$files"
}

# ---------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------

CHAIN_PID=""
cleanup() {
	if [ "$KEEP_RUNNING" = "1" ]; then
		echo ""
		echo "Leaving Hardhat node running on ${RPC_URL} -- --keep-running was set."
		echo "Stop it manually later with: pkill -f 'hardhat node --port ${PORT}'"
		return
	fi
	# Killing $CHAIN_PID alone isn't reliable: npx often spawns the actual
	# long-running hardhat process as a CHILD of the npx process it
	# returned, so $! only captures the wrapper's PID, which can exit on
	# its own while the real node keeps running. Match by the exact
	# command line instead, which is unambiguous.
	pkill -f "hardhat node --port ${PORT}" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------

if [ ! -x "$DVCS" ]; then
	echo "No CLI binary at ${DVCS} -- building it first..."
	(cd "${PROJECT_ROOT}/cli" && v -cc tcc -o dvcs .) || { echo "CLI build failed"; exit 1; }
fi
if [ ! -f "${PROJECT_ROOT}/build/DVCS.bin" ]; then
	echo "No compiled contract at build/DVCS.bin -- compiling it first..."
	(cd "$PROJECT_ROOT" && ./scripts/compile-contract.sh) || { echo "Contract compile failed"; exit 1; }
fi
if [ ! -d "${SCRIPT_DIR}/node_modules/hardhat" ]; then
	echo "Installing hardhat + ethers (one-time)..."
	(cd "$SCRIPT_DIR" && npm install --save-dev "hardhat@^2.22.0" ethers > /dev/null 2>&1) \
		|| { echo "npm install failed"; exit 1; }
fi
if curl -s -m 2 -X POST -H "Content-Type: application/json" \
	--data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC_URL" > /dev/null 2>&1; then
	echo "Something is already listening on ${RPC_URL}."
	echo "Either stop it, or pass a different port: ./demo.sh --port 8556"
	exit 1
fi

rm -rf "$WORKSPACE"
mkdir -p "$ALICE_DIR" "$BOB_DIR" "$PRIVATE_DIR"

# ---------------------------------------------------------------------
# Start chain + deploy (fully automatic -- this is what solves the
# "different address every time" problem: everything downstream reads
# CONTRACT/ALICE/BOB from here, nothing is ever hand-copied)
# ---------------------------------------------------------------------

banner "Starting a local Hardhat chain and deploying the contract"

cd "$SCRIPT_DIR"
npx hardhat node --port "$PORT" > "${WORKSPACE}/hardhat.log" 2>&1 &
CHAIN_PID=$!

printf "Waiting for the chain to be ready"
READY=0
for _ in $(seq 1 30); do
	if curl -s -m 2 -X POST -H "Content-Type: application/json" \
		--data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC_URL" > /dev/null 2>&1; then
		READY=1
		break
	fi
	printf "."
	sleep 1
done
echo ""
if [ "$READY" -ne 1 ]; then
	echo "Chain never became ready. Log:"
	cat "${WORKSPACE}/hardhat.log"
	exit 1
fi

DEPLOY_OUT=$(node -e "
const { ethers } = require('ethers');
const fs = require('fs');
(async () => {
  const provider = new ethers.JsonRpcProvider('${RPC_URL}');
  const signer = await provider.getSigner(0);
  const bytecode = '0x' + fs.readFileSync('${PROJECT_ROOT}/build/DVCS.bin', 'utf8').trim();
  const abi = JSON.parse(fs.readFileSync('${PROJECT_ROOT}/build/DVCS.abi', 'utf8'));
  const factory = new ethers.ContractFactory(abi, bytecode, signer);
  const contract = await factory.deploy();
  await contract.waitForDeployment();
  const accounts = await provider.send('eth_accounts', []);
  console.log('CONTRACT=' + await contract.getAddress());
  console.log('ALICE=' + accounts[0]);
  console.log('BOB=' + accounts[1]);
})();
")
CONTRACT=$(echo "$DEPLOY_OUT" | grep '^CONTRACT=' | cut -d= -f2)
ALICE=$(echo "$DEPLOY_OUT" | grep '^ALICE=' | cut -d= -f2)
BOB=$(echo "$DEPLOY_OUT" | grep '^BOB=' | cut -d= -f2)
if [ -z "$CONTRACT" ]; then
	echo "Deploy failed:"
	echo "$DEPLOY_OUT"
	exit 1
fi
echo "Contract deployed at ${CONTRACT}"
echo "Alice = ${ALICE}"
echo "Bob   = ${BOB}"

# ---------------------------------------------------------------------
# Scene 1 -- Alice's first repository
# ---------------------------------------------------------------------

banner "SCENE 1 -- Alice starts a project"
cd "$ALICE_DIR"
say "Alice initializes a repo and points it at our local chain."
run "$DVCS init"
run "$DVCS remote $RPC_URL $CONTRACT $ALICE"
say "This next command is a real transaction -- the repo now exists on-chain."
run "$DVCS repo-create acme-website"

say "Now she adds a small real project -- a task tracker, a few files -- and makes her first commit."
run "cp $SAMPLE_V1/*.html $SAMPLE_V1/*.css $SAMPLE_V1/*.js $SAMPLE_V1/*.md ."
tree_view "$ALICE_DIR" "acme-website"
run "$DVCS add index.html style.css app.js README.md"
run "$DVCS commit -m 'Initial task tracker'"
say "And pushes. Watch the output -- several separate transactions, not one."
run "$DVCS push"

status_line "ALICE"
commit_chain main

# ---------------------------------------------------------------------
# Scene 2 -- prove it's real
# ---------------------------------------------------------------------

banner "SCENE 2 -- Prove it's really on-chain"
say "The log and the changelog both read back real, confirmed transactions."
run "$DVCS log"
run "$DVCS changelog"

# ---------------------------------------------------------------------
# Scene 3 -- branching and inspection
# ---------------------------------------------------------------------

banner "SCENE 3 -- Branching, and inspecting history without checking it out"
run "$DVCS branch feature-darkmode"
run "$DVCS checkout feature-darkmode"
say "A real feature: dark mode. A new file, plus edits to two existing ones."
run "cp $SAMPLE_V2/index.html $SAMPLE_V2/style.css $SAMPLE_V2/darkmode.js ."
run "$DVCS add index.html style.css darkmode.js"
run "$DVCS commit -m 'Add dark mode toggle'"
say "Compare branches without switching to either."
run "$DVCS diff main feature-darkmode"
run "$DVCS show feature-darkmode"

say "Here's the shape of history so far -- two branches, one shared origin:"
commit_chain main
commit_chain feature-darkmode

# ---------------------------------------------------------------------
# Scene 4 -- identity + members
# ---------------------------------------------------------------------

banner "SCENE 4 -- Bob joins, added by handle instead of raw address"
say "Alice registers a human-readable handle for herself."
run "$DVCS identity-register 'alice@acme.example'"

say "Meanwhile, in Bob's own directory, he sets up and registers his own handle."
cd "$BOB_DIR"
run "$DVCS init"
run "$DVCS remote $RPC_URL $CONTRACT $BOB"
run "$DVCS identity-register 'bob@acme.example'"

cd "$ALICE_DIR"
say "Alice grants Bob access using only his handle -- never his raw address."
run "$DVCS member-add 'bob@acme.example' contributor"
run "$DVCS member-list"
run "$DVCS push feature-darkmode"

# ---------------------------------------------------------------------
# Scene 5 -- Bob's side
# ---------------------------------------------------------------------

banner "SCENE 5 -- Bob connects and pulls, with nothing but a name"
cd "$BOB_DIR"
run "$DVCS repo-connect $ALICE acme-website"
run "$DVCS pull"
run "$DVCS checkout main"
run "cat index.html"

say "Bob opens a pull request proposing his branch merge into main."
run "$DVCS pr-open feature-darkmode main 'Add dark mode toggle' 'Adds a dark/light theme switcher'"
say "Now watch what happens when the AUTHOR tries to approve their own PR."
run_expect_fail "$DVCS pr-approve 0"

# ---------------------------------------------------------------------
# Scene 6 -- review and merge
# ---------------------------------------------------------------------

banner "SCENE 6 -- Alice reviews and merges"
cd "$ALICE_DIR"
run "$DVCS pr-list"
run "$DVCS pr-approve 0"
run "$DVCS pr-merge 0"
run "$DVCS pull main"
run "$DVCS checkout main"
run "cat index.html"

say "The two branches are now one line of history again:"
commit_chain main
tree_view "$ALICE_DIR" "acme-website"

# ---------------------------------------------------------------------
# Scene 7 -- rollback
# ---------------------------------------------------------------------

banner "SCENE 7 -- Undo something: rollback"
say "Purely local, like git reset -- nothing on-chain moves yet."
FIRST_COMMIT=$($DVCS log 2>&1 | grep '^commit ' | tail -1 | awk '{print $2}')
run "$DVCS rollback ${FIRST_COMMIT:2:10}"
run "$DVCS log"

# ---------------------------------------------------------------------
# Scene 8 -- a real conflict
# ---------------------------------------------------------------------

banner "SCENE 8 -- A real conflict, handled honestly"
run "$DVCS checkout main"
run "$DVCS branch branch-a"
run "$DVCS branch branch-b"
say "Two developers each independently decide on a new accent color."
run "$DVCS checkout branch-a"
run "sed -i.bak 's/--accent: #3b6ff0;/--accent: #2ecc71;/' style.css && rm -f style.css.bak"
run "$DVCS add style.css && $DVCS commit -m 'Switch accent color to green'"
run "$DVCS checkout branch-b"
run "sed -i.bak 's/--accent: #3b6ff0;/--accent: #9b59b6;/' style.css && rm -f style.css.bak"
run "$DVCS add style.css && $DVCS commit -m 'Switch accent color to purple'"
run "$DVCS checkout branch-a"
say "Both branches changed the same file differently since diverging. Watch."
commit_chain branch-a
commit_chain branch-b
run "$DVCS rebase branch-b"
say "It stopped and named the conflict instead of silently picking a winner. Resolve it explicitly:"
run "$DVCS rebase branch-b --theirs"
commit_chain branch-a

# ---------------------------------------------------------------------
# Scene 9 -- privacy done honestly
# ---------------------------------------------------------------------

banner "SCENE 9 -- Privacy: encryption, not just an access-control flag"
say "A fresh directory, a fresh private repo -- this is a separate project from acme-website."
cd "$PRIVATE_DIR"
run "$DVCS init"
run "$DVCS remote $RPC_URL $CONTRACT $ALICE"
run "$DVCS repo-create secret-notes --private"
run "echo 'sensitive plans' > notes.txt"
run "$DVCS add notes.txt"
run "$DVCS commit -m 'notes'"
say "Marking a repo private can't hide it from a block explorer -- nothing can. Watch:"
run_expect_fail "$DVCS push"
say "So the CLI requires real encryption before it'll push content to a private repo."
run "$DVCS crypto-init 'demo-passphrase-2026'"
run "export DVCS_PASSPHRASE='demo-passphrase-2026'"
run "$DVCS push"

# ---------------------------------------------------------------------
# Wrap
# ---------------------------------------------------------------------

banner "That's the demo -- see TUTORIAL.md and README.md for everything else."

if [ "$KEEP_RUNNING" = "1" ]; then
	echo ""
	echo "Chain is still running at ${RPC_URL}. Contract: ${CONTRACT}"
	echo "Alice's workspace: ${ALICE_DIR}"
	echo "Bob's workspace:   ${BOB_DIR}"
fi
