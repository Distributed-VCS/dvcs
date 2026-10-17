#!/usr/bin/env bash
# Compiles contracts/DVCS.sol to build/DVCS.bin + build/DVCS.abi.
#
# Uses solc's --standard-json mode instead of the plain CLI flags because
# the plain flags don't expose `evmVersion` or `viaIR`, and this contract
# needs both: `viaIR` to avoid a "stack too deep" error from its pull
# request functions, and `evmVersion: paris` for compatibility with local
# dev chains (Ganache in particular) that lag mainnet's latest opcodes.
#
# Usage:
#   ./scripts/compile-contract.sh
#
# Requires solc or solcjs on PATH, or npx (which this script falls back to
# automatically) -- see SETUP.md step 5.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"
mkdir -p build

SOLC_CMD="npx -p solc solcjs"
if command -v solcjs >/dev/null 2>&1; then
	SOLC_CMD="solcjs"
elif command -v solc >/dev/null 2>&1; then
	SOLC_CMD="solc"
fi

TMP_INPUT="$(mktemp)"
TMP_OUTPUT="$(mktemp)"
trap 'rm -f "$TMP_INPUT" "$TMP_OUTPUT"' EXIT

cat > "$TMP_INPUT" <<'EOF'
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
EOF

python3 -c "
import json
d = json.load(open('${TMP_INPUT}'))
d['sources']['DVCS.sol']['content'] = open('contracts/DVCS.sol').read()
json.dump(d, open('${TMP_INPUT}', 'w'))
"

echo "Compiling with: ${SOLC_CMD} --standard-json"
${SOLC_CMD} --standard-json < "$TMP_INPUT" > "$TMP_OUTPUT" 2>/dev/null || true

# solcjs sometimes prefixes stdout with an unrelated informational line
# (e.g. about SMT solvers) before the actual JSON -- strip anything before
# the first '{'.
python3 -c "
import json, sys

with open('${TMP_OUTPUT}') as f:
    raw = f.read()
start = raw.find('{')
if start == -1:
    print('solc produced no JSON output:', file=sys.stderr)
    print(raw, file=sys.stderr)
    sys.exit(1)

d = json.loads(raw[start:])
errors = [e for e in (d.get('errors') or []) if e.get('severity') == 'error']
for e in d.get('errors') or []:
    print(e.get('formattedMessage', e.get('message', str(e))), file=sys.stderr)
if errors:
    sys.exit(1)

c = d['contracts']['DVCS.sol']['DVCS']
with open('build/DVCS.bin', 'w') as f:
    f.write(c['evm']['bytecode']['object'])
with open('build/DVCS.abi', 'w') as f:
    json.dump(c['abi'], f)
print('OK: build/DVCS.bin (' + str(len(c['evm']['bytecode']['object'])) + ' hex chars), build/DVCS.abi (' + str(len(c['abi'])) + ' entries)')
"
