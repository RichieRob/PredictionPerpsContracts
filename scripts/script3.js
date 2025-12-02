// scripts/initTestMarket.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();

  const filePath = path.join(__dirname, "../deployments.json");
  if (!fs.existsSync(filePath)) {
    throw new Error("deployments.json not found. Run deployment scripts first.");
  }
  const deployments = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const core = deployments.core || {};
  const lmsrInfo = deployments.lmsr || {};

  const ledgerAddress = core.Ledger;
  const dmmAddress = lmsrInfo.LMSRMarketMaker;

  if (!ledgerAddress) {
    throw new Error("Ledger address not found in deployments.json.");
  }
  if (!dmmAddress) {
    throw new Error("LMSRMarketMaker address not found in deployments.json. Run deployLMSRAndMarket.js first.");
  }

  console.log("Using deployer:", deployer.address);
  console.log("Attaching to Ledger at:", ledgerAddress);
  console.log("Using LMSR DMM at:", dmmAddress);

  const Ledger = await ethers.getContractFactory("Ledger");
  const ledger = Ledger.attach(ledgerAddress);

  const LMSRMarketMaker = await ethers.getContractFactory("LMSRMarketMaker");
  const lmsr = LMSRMarketMaker.attach(dmmAddress);

  // 1) Create Footie market
  const iscAmount    = ethers.parseUnits("100000", 6); //$100k of ISC liqudity
  const txMarket = await ledger.createMarket(
    "Footie",
    "FBL",
    dmmAddress,           // LMSR as DMM
    iscAmount,            // iscAmount
    false,                // doesResolve
    ethers.ZeroAddress,   // oracle
    "0x",                  // oracleParams
    true
  );
  await txMarket.wait();
  console.log("⚽ Footie market created");

  // 2) Get new marketId (latest)
  const marketIds = await ledger.getMarkets();
  const marketId = marketIds[marketIds.length - 1];
  console.log("New Footie marketId:", marketId.toString());

  // 3) Create positions: Home, Away, Draw (on ledger)
  await (await ledger.createPosition(marketId, "Home Win", "HME")).wait();
  await (await ledger.createPosition(marketId, "Away Win", "AWY")).wait();
  await (await ledger.createPosition(marketId, "Draw", "DRW")).wait();
  console.log("Created positions: Home / Away / Draw");

  // 4) Initialise this market inside LMSR

  const positionIds = await ledger.getMarketPositions(marketId);
  console.log(
    "ℹ️ Footie ledger position IDs for LMSR init:",
    positionIds.map((id) => id.toString())
  );

  const priorR = ethers.parseUnits("1", 18);
  const initialPositions = positionIds.map((id) => [id, priorR]);
  const reserve0 = ethers.parseUnits("1", 18);

  const txInit = await lmsr.initMarket(
    marketId,
    initialPositions,
    iscAmount,   // liabilityUSDC ~= ISC
    reserve0,
    true
  );
  await txInit.wait();
  console.log("✅ LMSR initialised for Footie market", marketId.toString());
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
