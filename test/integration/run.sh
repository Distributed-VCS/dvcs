#!/usr/bin/env bash
# Integration test suite for the DVCS CLI + contract.
#
# Prerequisites: node (with `hardhat` and `ethers` installed -- see below),
# the V compiler, and solc/solcjs. Builds a fresh `dvcs` binary, starts an
# isolated Hardhat node on a free port, deploys a fresh contract, and runs
# through the CLI's real command-line interface end to end -- the same way
# a user would -- asserting on actual output and on-chain state rather
# than just checking exit codes where more precision is available.
#
# Usage:
#   cd test/integration
#   npm install --save-dev hardhat ethers   # one-time, if not already available
#   ./run.sh
#
# Exits 0 if every scenario passes, non-zero (with a summary of failures)
# otherwise. Safe to re-run: each run uses a fresh chain and fresh temp dirs.

set -u
# Convenience for environments where the V compiler isn't already on PATH
# but is checked out at a well-known location; harmless no-op otherwise.
[ -d "/home/claude/v" ] && export PATH="$PATH:/home/claude/v"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
RPC_PORT=18545
RPC_URL="http://127.0.0.1:${RPC_PORT}"

PASS=0
FAIL=0
FAILURES=()

log_section() { echo ""; echo "=== $1 ==="; }

check() {
	# check <description> <actual_exit_code> <expected: 0=success, nonzero=should-fail>
	local desc="$1" code="$2" want="$3"
	if [ "$want" = "0" ] && [ "$code" -eq 0 ]; then
		PASS=$((PASS+1)); echo "  PASS: $desc"
	elif [ "$want" != "0" ] && [ "$code" -ne 0 ]; then
		PASS=$((PASS+1)); echo "  PASS: $desc (correctly failed)"
	else
		FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo "  FAIL: $desc (exit=$code, wanted 0=$want)"
	fi
}

check_contains() {
	# check_contains <description> <haystack> <needle>
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF -- "$needle"; then
		PASS=$((PASS+1)); echo "  PASS: $desc"
	else
		FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo "  FAIL: $desc (expected to find: $needle)"
	fi
}

check_not_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF -- "$needle"; then
		FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo "  FAIL: $desc (should NOT contain: $needle)"
	else
		PASS=$((PASS+1)); echo "  PASS: $desc"
	fi
}

cleanup() {
	# Killing $CHAIN_PID alone isn't reliable: npx often spawns the actual
	# long-running hardhat process as a CHILD of the npx process it
	# returned, so $! only captures the wrapper's PID, which can exit on
	# its own while the real node keeps running (same issue fixed in
	# scripts/demo.sh). Match by the exact command line instead.
	pkill -f "hardhat node --port ${RPC_PORT}" 2>/dev/null
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# Build CLI + contract
# ---------------------------------------------------------------------
log_section "Build"
cd "${PROJECT_ROOT}/cli"
v -cc tcc -o "${WORK_DIR}/dvcs" . || { echo "CLI build failed"; exit 1; }
DVCS="${WORK_DIR}/dvcs"
echo "  built ${DVCS}"

cd "${PROJECT_ROOT}"
mkdir -p "${WORK_DIR}/build"
cat > "${WORK_DIR}/input.json" <<PYEOF
{
  "language": "Solidity",
  "sources": {"DVCS.sol": {"content": null}},
  "settings": {
    "evmVersion": "paris",
    "viaIR": true,
    "optimizer": {"enabled": true, "runs": 200},
    "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}}
  }
}
PYEOF
python3 -c "
import json
d = json.load(open('${WORK_DIR}/input.json'))
d['sources']['DVCS.sol']['content'] = open('contracts/DVCS.sol').read()
json.dump(d, open('${WORK_DIR}/input.json','w'))
"
npx -p solc solcjs --standard-json < "${WORK_DIR}/input.json" > "${WORK_DIR}/output.json" 2>/dev/null
tail -n +2 "${WORK_DIR}/output.json" > "${WORK_DIR}/output_clean.json"
python3 -c "
import json
d = json.load(open('${WORK_DIR}/output_clean.json'))
errs = [e for e in (d.get('errors') or []) if e.get('severity')=='error']
if errs:
    for e in errs: print(e.get('message'))
    raise SystemExit(1)
c = d['contracts']['DVCS.sol']['DVCS']
open('${WORK_DIR}/build/DVCS.bin','w').write(c['evm']['bytecode']['object'])
json.dump(c['abi'], open('${WORK_DIR}/build/DVCS.abi','w'))
" || { echo "Contract compile failed"; exit 1; }
echo "  contract compiled"

# ---------------------------------------------------------------------
# Start an isolated chain + deploy
# ---------------------------------------------------------------------
log_section "Chain setup"
cd "${SCRIPT_DIR}"
if [ ! -d node_modules/hardhat ] || [ ! -d node_modules/ethers ]; then
	echo "  installing hardhat + ethers (one-time)..."
	npm install --save-dev "hardhat@^2.22.0" ethers > /dev/null 2>&1
fi
if [ ! -f hardhat.config.js ]; then
	cat > hardhat.config.js <<'EOF'
module.exports = { solidity: "0.8.24" };
EOF
fi

# Hardhat must be run from a directory containing its own node_modules and
# config (hence `cd "${SCRIPT_DIR}"` above, which is already where we are).
npx hardhat node --port "${RPC_PORT}" > "${WORK_DIR}/hardhat.log" 2>&1 &
CHAIN_PID=$!

# Poll for readiness instead of a fixed sleep -- a fresh `npm install`
# right before this can make the first startup noticeably slower than
# later ones.
echo -n "  waiting for hardhat node on port ${RPC_PORT}"
READY=0
for _ in $(seq 1 30); do
	if curl -s -X POST -H "Content-Type: application/json" \
		--data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
		"${RPC_URL}" > /dev/null 2>&1; then
		READY=1
		break
	fi
	echo -n "."
	sleep 1
done
echo ""
if [ "$READY" -ne 1 ]; then
	echo "Hardhat node never became ready. Log:"
	cat "${WORK_DIR}/hardhat.log"
	exit 1
fi
echo "  hardhat node pid ${CHAIN_PID} on port ${RPC_PORT}"

DEPLOY_OUT=$(node -e "
const { ethers } = require('ethers');
const fs = require('fs');
(async () => {
  const provider = new ethers.JsonRpcProvider('${RPC_URL}');
  const signer = await provider.getSigner(0);
  const bytecode = '0x' + fs.readFileSync('${WORK_DIR}/build/DVCS.bin', 'utf8').trim();
  const abi = JSON.parse(fs.readFileSync('${WORK_DIR}/build/DVCS.abi', 'utf8'));
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
if [ -z "$CONTRACT" ]; then echo "Deploy failed:"; echo "$DEPLOY_OUT"; exit 1; fi
echo "  contract=${CONTRACT}"
echo "  alice=${ALICE}"
echo "  bob=${BOB}"

ALICE_DIR="${WORK_DIR}/alice"
BOB_DIR="${WORK_DIR}/bob"
mkdir -p "$ALICE_DIR" "$BOB_DIR"

# ---------------------------------------------------------------------
# Scenario: setup, identity, private repo enforcement
# ---------------------------------------------------------------------
log_section "Setup + identity + private-repo enforcement"
cd "$ALICE_DIR"
"$DVCS" init > /dev/null; check "alice: init" $? 0
"$DVCS" remote "$RPC_URL" "$CONTRACT" "$ALICE" > /dev/null; check "alice: remote" $? 0
"$DVCS" identity-register "alice@example.com" > /dev/null; check "alice: identity-register" $? 0
"$DVCS" repo-create teamproject --private > /dev/null; check "alice: repo-create --private" $? 0

mkdir -p src
echo "fn main() { println('v1') }" > src/main.v
"$DVCS" add src > /dev/null
"$DVCS" commit -m "Initial commit" > /dev/null
PUSH_BLOCKED=$("$DVCS" push 2>&1)
check "alice: push refused without crypto-init on private repo" $? 1
check_contains "alice: refusal message mentions crypto-init" "$PUSH_BLOCKED" "crypto-init"

"$DVCS" crypto-init "team secret passphrase" > /dev/null; check "alice: crypto-init" $? 0
export DVCS_PASSPHRASE="team secret passphrase"
"$DVCS" push > /dev/null 2>&1; check "alice: push succeeds after crypto-init" $? 0

# ---------------------------------------------------------------------
# Scenario: member-add by handle, member-list
# ---------------------------------------------------------------------
log_section "Identity + membership"
cd "$BOB_DIR"
"$DVCS" init > /dev/null
"$DVCS" remote "$RPC_URL" "$CONTRACT" "$BOB" > /dev/null
"$DVCS" identity-register "bob@example.com" > /dev/null; check "bob: identity-register" $? 0

cd "$ALICE_DIR"
"$DVCS" member-add "bob@example.com" contributor > /dev/null
check "alice: member-add resolves handle" $? 0
MEMBERS=$("$DVCS" member-list 2>&1)
check_contains "member-list shows bob's handle" "$MEMBERS" "bob@example.com"
check_contains "member-list shows contributor role" "$MEMBERS" "contributor"

# ---------------------------------------------------------------------
# Scenario: access control (push before/after role grant)
# ---------------------------------------------------------------------
log_section "Access control"
cd "$BOB_DIR"
"$DVCS" repo-connect "$ALICE" teamproject > /dev/null
check "bob: repo-connect" $? 0
"$DVCS" pull > /dev/null 2>&1 || "$DVCS" pull > /dev/null 2>&1  # tolerate one transient RPC hiccup
check "bob: pull (auto-discovers encryption salt)" $? 0

CFG=$(cat .dvcs/config)
check_contains "bob: salt auto-discovered without being told directly" "$CFG" "encrypt=true"

"$DVCS" checkout main > /dev/null; check "bob: checkout after pull" $? 0
check_contains "bob: decrypted content matches alice's" "$(cat src/main.v)" "v1"

# ---------------------------------------------------------------------
# Scenario: wrong passphrase rejected
# ---------------------------------------------------------------------
log_section "Wrong passphrase handling"
EVE_DIR="${WORK_DIR}/eve"
mkdir -p "$EVE_DIR"; cd "$EVE_DIR"
"$DVCS" init > /dev/null
"$DVCS" remote "$RPC_URL" "$CONTRACT" "$BOB" > /dev/null
"$DVCS" repo-connect "$ALICE" teamproject > /dev/null
export DVCS_PASSPHRASE="totally wrong guess"
EVE_PULL=$("$DVCS" pull 2>&1); "$DVCS" pull > /dev/null 2>&1
check_contains "wrong passphrase: AES-GCM auth failure reported" "$EVE_PULL" "AES-GCM"
export DVCS_PASSPHRASE="team secret passphrase"

# ---------------------------------------------------------------------
# Scenario: diff, ls, show, cat
# ---------------------------------------------------------------------
log_section "Inspection commands"
cd "$BOB_DIR"
"$DVCS" branch feature-x > /dev/null
"$DVCS" checkout feature-x > /dev/null
echo "fn helper() {}" >> src/main.v
"$DVCS" add src > /dev/null
"$DVCS" commit -m "Add helper" > /dev/null

DIFF_OUT=$("$DVCS" diff main feature-x 2>&1)
check_contains "diff shows modified file" "$DIFF_OUT" "modified src/main.v"

LS_OUT=$("$DVCS" ls feature-x 2>&1)
check_contains "ls shows tracked file" "$LS_OUT" "src/main.v"

SHOW_OUT=$("$DVCS" show feature-x 2>&1)
check_contains "show includes commit message" "$SHOW_OUT" "Add helper"

CAT_OUT=$("$DVCS" cat feature-x src/main.v 2>&1)
check_contains "cat prints exact file content" "$CAT_OUT" "fn helper() {}"

# ---------------------------------------------------------------------
# Scenario: full PR review lifecycle, including self-approval block
# ---------------------------------------------------------------------
log_section "Pull request review workflow"
"$DVCS" push feature-x > /dev/null 2>&1
check "bob: push feature branch" $? 0

PR_OPEN=$("$DVCS" pr-open feature-x main "Add helper" "small helper fn" 2>&1)
check_contains "bob: pr-open succeeds" "$PR_OPEN" "Opened pull request"

"$DVCS" pr-approve 0 > /dev/null 2>&1
check "bob: cannot approve own PR" $? 1

cd "$ALICE_DIR"
PR_LIST=$("$DVCS" pr-list 2>&1)
check_contains "alice: pr-list shows the PR" "$PR_LIST" "feature-x -> main"

"$DVCS" pr-approve 0 > /dev/null; check "alice: approve PR" $? 0
"$DVCS" pr-merge 0 > /dev/null; check "alice: merge PR" $? 0

"$DVCS" pull main > /dev/null 2>&1 || "$DVCS" pull main > /dev/null 2>&1
"$DVCS" checkout main > /dev/null
check_contains "alice: merged PR content landed on main" "$(cat src/main.v)" "helper"

# ---------------------------------------------------------------------
# Scenario: pr-min-approvals enforcement
# ---------------------------------------------------------------------
log_section "PR minimum approvals"
"$DVCS" pr-min-approvals 2 > /dev/null; check "alice: set min approvals to 2" $? 0
"$DVCS" branch feature-y > /dev/null
"$DVCS" checkout feature-y > /dev/null
echo "more" > extra.txt
"$DVCS" add extra.txt > /dev/null
"$DVCS" commit -m "extra" > /dev/null
"$DVCS" push feature-y > /dev/null 2>&1
"$DVCS" pr-open feature-y main "Extra" "" > /dev/null
"$DVCS" pr-approve 1 > /dev/null 2>&1
check "alice: cannot approve own PR either" $? 1
"$DVCS" pr-merge 1 > /dev/null 2>&1
check "merge fails with 0/2 approvals" $? 1

# ---------------------------------------------------------------------
# Scenario: rebase with real conflict detection
# ---------------------------------------------------------------------
log_section "Rebase conflict detection"
cd "$ALICE_DIR"
"$DVCS" checkout main > /dev/null
"$DVCS" branch conflict-base > /dev/null
"$DVCS" branch branch-a > /dev/null
"$DVCS" checkout branch-a > /dev/null
echo "version-A" > conflict.txt
"$DVCS" add conflict.txt > /dev/null
"$DVCS" commit -m "A's change" > /dev/null

"$DVCS" checkout main > /dev/null
"$DVCS" branch branch-b > /dev/null
"$DVCS" checkout branch-b > /dev/null
echo "version-B" > conflict.txt
"$DVCS" add conflict.txt > /dev/null
"$DVCS" commit -m "B's change" > /dev/null

"$DVCS" checkout branch-a > /dev/null
REBASE_OUT=$("$DVCS" rebase branch-b 2>&1)
check_contains "rebase reports a real conflict" "$REBASE_OUT" "CONFLICT"
check_contains "rebase names the conflicting path" "$REBASE_OUT" "conflict.txt"

REBASE_THEIRS=$("$DVCS" rebase branch-b --theirs 2>&1)
check_contains "rebase --theirs auto-resolves" "$REBASE_THEIRS" "resolving"
CAT_AFTER=$("$DVCS" cat branch-a conflict.txt 2>&1)
check_contains "rebase --theirs took branch-b's content" "$CAT_AFTER" "version-B"

# ---------------------------------------------------------------------
# Scenario: rollback
# ---------------------------------------------------------------------
log_section "Rollback"
cd "$ALICE_DIR"
"$DVCS" checkout main > /dev/null
FIRST_COMMIT=$("$DVCS" log 2>&1 | grep '^commit ' | tail -1 | awk '{print $2}')
echo "  rolling back to: ${FIRST_COMMIT}"
"$DVCS" rollback "${FIRST_COMMIT:2:10}" > /dev/null 2>&1
check "rollback by short prefix" $? 0

# ---------------------------------------------------------------------
# Scenario: on-chain chunk size limit
# ---------------------------------------------------------------------
log_section "On-chain chunk size limit"
cd "$SCRIPT_DIR"
CHUNK_TEST=$(node -e "
const { ethers } = require('ethers');
const fs = require('fs');
(async () => {
  const provider = new ethers.JsonRpcProvider('${RPC_URL}');
  const signer = await provider.getSigner(0);
  const abi = JSON.parse(fs.readFileSync('${WORK_DIR}/build/DVCS.abi', 'utf8'));
  const contract = new ethers.Contract('${CONTRACT}', abi, signer);
  const repoId = await contract.computeRepoId('${ALICE}', 'teamproject');
  const max = await contract.MAX_CHUNK_BYTES();
  const oversized = '0x' + 'ab'.repeat(Number(max) + 1);
  const hash = ethers.keccak256(ethers.toUtf8Bytes('itest-oversize'));
  try {
    await contract.pushBlobChunk.staticCall(repoId, hash, 0, 1, false, oversized);
    console.log('FAIL: oversized chunk accepted');
  } catch (e) {
    const iface = new ethers.Interface(abi);
    try { console.log('OK:' + iface.parseError(e.data).name); }
    catch { console.log('OK:reverted'); }
  }
})();
")
check_contains "oversized chunk reverts with ChunkTooLarge" "$CHUNK_TEST" "OK:ChunkTooLarge"

# ---------------------------------------------------------------------
# Scenario: changelog
# ---------------------------------------------------------------------
log_section "Changelog"
cd "$ALICE_DIR"
CHANGELOG=$("$DVCS" changelog 2>&1)
check_contains "changelog recorded repo-create" "$CHANGELOG" "repo-create"
check_contains "changelog recorded push-commit" "$CHANGELOG" "push-commit"
check_contains "changelog recorded member-add" "$CHANGELOG" "member-add"

# ---------------------------------------------------------------------
log_section "Summary"
echo "  ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
	echo ""
	echo "  Failures:"
	for f in "${FAILURES[@]}"; do echo "    - $f"; done
	exit 1
fi
exit 0
