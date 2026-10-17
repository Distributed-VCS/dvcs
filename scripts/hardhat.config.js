// Minimal config -- this project doesn't use Hardhat's own compile/deploy
// tooling (contracts/DVCS.sol is compiled by scripts/compile-contract.sh
// via solc directly, and deployed by scripts/deploy.js via plain ethers.js
// against whatever RPC endpoint you point it at). This file exists only so
// `npx hardhat node` has a config to run against, giving you a local
// Ethereum-compatible dev chain with unlocked, pre-funded accounts.
module.exports = {
  solidity: "0.8.24",
};
