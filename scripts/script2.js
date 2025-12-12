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

  console.log("ℹ️ Using core contracts:");
  console.log("   MockUSDC:", MOCK_USDC_ADDRESS);
  console.log("   Ledger  :", LEDGER_ADDRESS);

  // ------------------------------------------------------------
  // 1) Mint deployer USDC
  // ------------------------------------------------------------
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.attach(MOCK_USDC_ADDRESS);

  const amount = ethers.parseUnits("1000000", 6); // 1,000,000 USDC
  const mintTx = await mockUSDC.mint(deployer.address, amount);
  await mintTx.wait();
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
  // 3) Attach to Ledger (ABI only, no library linking)
  // ------------------------------------------------------------
  const ledger = await ethers.getContractAt("Ledger", LEDGER_ADDRESS);
  console.log("🔗 Attached to Ledger at:", await ledger.getAddress());

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
  // 5) Create market (ISC > 0, no resolve, no oracle, no fees)
  // ------------------------------------------------------------
  const marketName   = "Test Market";
  const marketTicker = "TEST";
  const iscAmount    = ethers.parseUnits("100000", 6); // 100,000 ISC

  const doesResolve  = false;
  const oracle       = ethers.ZeroAddress;
  const oracleParams = "0x";

  // New fee / whitelist params (mirroring tests)
  const feeBps               = 0;                // no trading fee
  const marketCreator        = deployer.address; // same pattern as tests (owner)
  const feeWhitelistAccounts = [];               // empty
  const hasWhitelist         = false;            // whitelist disabled forever

  let marketId;

  try {
    const tx = await ledger.createMarket(
      marketName,
      marketTicker,
      lmsr.target,
      iscAmount,
      doesResolve,
      oracle,
      oracleParams,
      feeBps,
      marketCreator,
      feeWhitelistAccounts,
      hasWhitelist
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
  // 6) Define 20 positions to create
  // ------------------------------------------------------------
  const positions = [
    { name: "Apple",            ticker: "APL" },
    { name: "Banana",           ticker: "BAN" },
    { name: "Cucumber",         ticker: "CUC" },
    { name: "Dragon Fruit",     ticker: "DFT" },
    { name: "Elderberry",       ticker: "ELD" },
    { name: "Fig Supreme",      ticker: "FIG" },
    { name: "Grape Cluster",    ticker: "GRP" },
    { name: "Honeydew",         ticker: "HNY" },
    { name: "Iceberg Lettuce",  ticker: "ICE" },
    { name: "Jackfruit",        ticker: "JKF" },
    { name: "Kiwi Slice",       ticker: "KIW" },
    { name: "Lemon Zest",       ticker: "LMN" },
    { name: "Mango Storm",      ticker: "MNG" },
    { name: "Nectarine",        ticker: "NEC" },
    { name: "Orange Blaze",     ticker: "ORG" },
    { name: "Papaya Burst",     ticker: "PAP" },
    { name: "Quinoa Bowl",      ticker: "QNB" },
    { name: "Raspberry Rush",   ticker: "RSP" },
    { name: "Strawberry Sun",   ticker: "STW" },
    { name: "Tomato Bomb",      ticker: "TMT" },
  ];

  // ------------------------------------------------------------
  // 7) Create positions on the LEDGER in a single tx
  // ------------------------------------------------------------
  try {
    const txPos = await ledger.createPositions(
      marketId,
      positions,
      {
        gasLimit: 12_000_000n,
      }
    );
    const receipt = await txPos.wait();

    console.log(
      `✅ Created ${positions.length} positions in one tx – gas used: ${receipt.gasUsed.toString()}`
    );
  } catch (err) {
    console.error("❌ createPositions reverted:", err.message);
    return;
  }

  // ------------------------------------------------------------
  // 8) Initialise LMSR for this market
  // ------------------------------------------------------------

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
  // 9) Save LMSR + market details
  // ------------------------------------------------------------
  const lmsrData = {
    LMSRMarketMaker: lmsr.target,
    marketId: marketId.toString(),
    marketName,
    marketTicker,
  };

  const existingData = JSON.parse(fs.readFileSync(filePath, "utf8"));
  existingData.lmsr = lmsrData;
  fs.writeFileSync(filePath, JSON.stringify(existingData, null, 2));
  console.log(`LMSR and market details saved to ${filePath}`);

  console.log("✅ Script completed.");
}

main().catch((error) => {
  console.error("❌ Fatal script failure:", error);
  process.exitCode = 1;
});
