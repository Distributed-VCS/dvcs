// Deploys build/DVCS.bin + build/DVCS.abi (produced by compiling
// contracts/DVCS.sol -- see SETUP.md) to whatever JSON-RPC endpoint you
// point it at, using the first unlocked account the node exposes. Written
// against a local Hardhat node (`npx hardhat node`, see SETUP.md step 7),
// but works against any Ethereum-compatible node with unlocked accounts
// (Anvil, Ganache, etc.) -- it's a plain ethers.js script, not a Hardhat
// deployment plugin.
//
// Usage:
//   cd scripts
//   npm install               # one-time
//   node deploy.js [rpc-url]  # defaults to http://127.0.0.1:8545
//
// Prints the deployed contract address and the accounts the node exposes,
// which is exactly what `dvcs remote <rpc-url> <contract-address>
// <account-address>` needs.

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const RPC_URL = process.argv[2] || "http://127.0.0.1:8545";
const BUILD_DIR = path.join(__dirname, "..", "build");

async function main() {
  const binPath = path.join(BUILD_DIR, "DVCS.bin");
  const abiPath = path.join(BUILD_DIR, "DVCS.abi");

  if (!fs.existsSync(binPath) || !fs.existsSync(abiPath)) {
    console.error(`Missing ${binPath} or ${abiPath}.`);
    console.error("Compile the contract first -- see SETUP.md step 5.");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(RPC_URL);

  let accounts;
  try {
    accounts = await provider.send("eth_accounts", []);
  } catch (e) {
    console.error(`Could not reach a node at ${RPC_URL}: ${e.message}`);
    console.error("Is your local dev chain (Anvil/Hardhat/Ganache) running?");
    process.exit(1);
  }
  if (!accounts || accounts.length === 0) {
    console.error(`Node at ${RPC_URL} exposed no accounts.`);
    console.error("Start a local dev chain first -- see SETUP.md step 7 (`npx hardhat node`).");
    process.exit(1);
  }

  const signer = await provider.getSigner(0);
  const bytecode = "0x" + fs.readFileSync(binPath, "utf8").trim();
  const abi = JSON.parse(fs.readFileSync(abiPath, "utf8"));

  console.log(`Deploying to ${RPC_URL} from ${accounts[0]} ...`);
  const factory = new ethers.ContractFactory(abi, bytecode, signer);
  const contract = await factory.deploy();
  await contract.waitForDeployment();
  const address = await contract.getAddress();

  console.log("");
  console.log("Deployed.");
  console.log(`  contract: ${address}`);
  console.log(`  accounts: ${accounts.join(", ")}`);
  console.log("");
  console.log("Next step:");
  console.log(`  dvcs remote ${RPC_URL} ${address} ${accounts[0]}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
