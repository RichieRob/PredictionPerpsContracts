// scripts/ping.js
const { ethers } = require("hardhat");

async function main() {
  const block = await ethers.provider.getBlockNumber();
  console.log("Current block:", block);
}

main().catch((err) => {
  console.error("Ping failed:", err);
  process.exit(1);
});
