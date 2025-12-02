// scripts/deployLMSRAndMarket.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("🚀 Running LMSR and market deployment with account:", deployer.address);

  // Load core deployments
  const filePath = path.join(__dirname, "../deployments.json");
  if (!fs.existsSync(filePath)) {
    throw new Error("deployments.json not found. Run deployCore.js first.");
  }
  const deployments = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const core = deployments.core || {};
  const MOCK_USDC_ADDRESS = core.MockUSDC;
  const LEDGER_ADDRESS = core.Ledger;

  if (!MOCK_USDC_ADDRESS || !LEDGER_ADDRESS) {
    throw new Error("Missing core addresses in deployments.json. Run deployCore.js first.");
  }

  // ------------------------------------------------------------
  // 1) Mint deployer USDC
  // ------------------------------------------------------------
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.attach(MOCK_USDC_ADDRESS);

  const amount = ethers.parseUnits("1000000", 6); // 1,000,000 USDC
  await mockUSDC.mint(deployer.address, amount);
  console.log("💰 Minted 1,000,000 USDC to deployer");

  // ------------------------------------------------------------
  // 2) Deploy LMSR (constructor = governor, ledger)
  // ------------------------------------------------------------
  const LMSRMarketMaker = await ethers.getContractFactory("LMSRMarketMaker");
  const lmsr = await LMSRMarketMaker.deploy(
    deployer.address, // governor
    LEDGER_ADDRESS    // ledger
  );
  await lmsr.waitForDeployment();
  console.log("📡 LMSRMarketMaker deployed:", lmsr.target);

  // ------------------------------------------------------------
  // 3) Attach to Ledger
  // ------------------------------------------------------------
  const Ledger = await ethers.getContractFactory("Ledger");
  const ledger = await Ledger.attach(LEDGER_ADDRESS);

  // ------------------------------------------------------------
  // 4) Whitelist LMSR as approved DMM
  // ------------------------------------------------------------
  try {
    const txAllow = await ledger.allowDMM(lmsr.target, true);
    await txAllow.wait();
    console.log("✅ LMSR allowed as DMM");
  } catch (err) {
    console.error("❌ allowDMM reverted:", err.message);
    return;
  }

  // ------------------------------------------------------------
  // 5) Create market (ISC > 0, no resolve, no oracle)
  // ------------------------------------------------------------
  const marketName   = "Test Market";
  const marketTicker = "TEST";
  const iscAmount    = ethers.parseUnits("100000", 6); // 100,000 ISC

  const doesResolve  = false;
  const oracle       = ethers.ZeroAddress;
  const oracleParams = "0x";

  let marketId;

  try {
    const tx = await ledger.createMarket(
      marketName,
      marketTicker,
      lmsr.target,
      iscAmount,
      doesResolve,
      oracle,
      oracleParams
    );
    const receipt = await tx.wait();

    let parsed;
    for (const log of receipt.logs) {
      try {
        const ev = ledger.interface.parseLog(log);
        if (ev.name === "MarketCreated") {
          parsed = ev;
          break;
        }
      } catch (_) {}
    }

    if (!parsed) {
      throw new Error("MarketCreated event not found in logs");
    }

    marketId = parsed.args.marketId;
    console.log(`🎉 Market created with ID: ${marketId.toString()}`);
  } catch (err) {
    console.error("❌ createMarket reverted:", err.message);
    return;
  }

  // ------------------------------------------------------------
  // 6) Create 7 positions on the LEDGER
  // ------------------------------------------------------------
  const positions = [
    { name: "Position 1", ticker: "POS1" },
    { name: "Position 2", ticker: "POS2" },
    { name: "Position 3", ticker: "POS3" },
    { name: "Position 4", ticker: "POS4" },
    { name: "Position 5", ticker: "POS5" },
    { name: "Position 6", ticker: "POS6" },
    { name: "Position 7", ticker: "POS7" },
  ];

  try {
    const txPos = await ledger.createPositions(marketId, positions);
    await txPos.wait();
    console.log("📍 Created 7 positions in market", marketId.toString());
  } catch (err) {
    console.error("❌ createPositions reverted:", err.message);
    return;
  }

  // ------------------------------------------------------------
  // 7) Initialise LMSR for this market
  // ------------------------------------------------------------

  // Get the ledger position IDs we just created
  const positionIds = await ledger.getMarketPositions(marketId);
  console.log(
    "ℹ️ Ledger position IDs for LMSR init:",
    positionIds.map((id) => id.toString())
  );

  // Equal priors, 1.0 each in 1e18
  const priorR = ethers.parseUnits("1", 18);

  // Solidity tuple is (uint256 ledgerPositionId, int256 r)
  const initialPositions = positionIds.map((id) => [id, priorR]);

  // Reserve mass scale (you've used 1e18 in tests)
  const reserve0 = ethers.parseUnits("1", 18);

  const txInit = await lmsr.initMarket(
    marketId,
    initialPositions,
    iscAmount,   // liabilityUSDC = ISC
    reserve0,
    true        // isExpanding
  );
  await txInit.wait();
  console.log("✅ LMSR initialised for market", marketId.toString());

  // ------------------------------------------------------------
  // 8) Save LMSR + market details
  // ------------------------------------------------------------
  const lmsrData = {
    LMSRMarketMaker: lmsr.target,
    marketId: marketId.toString(),
    marketName,
    marketTicker,
  };

  let existingData = JSON.parse(fs.readFileSync(filePath, "utf8"));
  existingData.lmsr = lmsrData;
  fs.writeFileSync(filePath, JSON.stringify(existingData, null, 2));
  console.log(`LMSR and market details saved to ${filePath}`);

  console.log("✅ Script completed.");
}

main().catch((error) => {
  console.error("❌ Fatal script failure:", error);
  process.exitCode = 1;
});
