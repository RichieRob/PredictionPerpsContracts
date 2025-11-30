// scripts/initTestMarket.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();

  // Load deployments (assumes most recent is from deployments.json)
  const filePath = path.join(__dirname, "../deployments.json");
  if (!fs.existsSync(filePath)) {
    throw new Error("deployments.json not found. Run deployment scripts first.");
  }
  const deployments = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const core = deployments.core || {};
  const ledgerAddress = core.Ledger;

  if (!ledgerAddress) {
    throw new Error("Ledger address not found in deployments.json.");
  }

  // Optional: If LMSR is needed, load it too
  const lmsr = deployments.lmsr;
  const dmmAddress = lmsr.LMSRMarketMaker;

  console.log("Using deployer:", deployer.address);
  console.log("Attaching to Ledger at:", ledgerAddress);

  const Ledger = await ethers.getContractFactory("Ledger");
  const ledger = Ledger.attach(ledgerAddress);

  // 1) Create a simple market
  const txMarket = await ledger.createMarket(
    "Footie",
    "FBL",
    dmmAddress,   // dmm (uses latest LMSR if available)
    10000000,     // iscAmount
    false,        // doesResolve
    ethers.ZeroAddress, // oracle
    "0x"          // oracleParams
  );
  await txMarket.wait();
  console.log("Market created");

  // 2) Get new marketId (lookup most recent market)
  const marketIds = await ledger.getMarkets();
  const marketId = marketIds[marketIds.length - 1];
  console.log("New marketId:", marketId.toString());

  // 3) Create positions: Home, Away, Draw
  await (await ledger.createPosition(marketId, "Home Win", "HME")).wait();
  await (await ledger.createPosition(marketId, "Away Win", "AWY")).wait();
  await (await ledger.createPosition(marketId, "Draw", "DRW")).wait();

  console.log("Created positions: Home / Away / Draw");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});