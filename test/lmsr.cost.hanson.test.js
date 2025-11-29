// test/lmsr.cost.hanson.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const WAD = 10n ** 18n;
const usdcUnits = (n) => BigInt(n) * 1_000_000n; // 6 dp

async function setupLmsr() {
  const [owner, trader, governor] = await ethers.getSigners();

  // Mock USDC (not actually used here, but keeps pattern consistent)
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  // Mock ledger
  const MockLedger = await ethers.getContractFactory("MockLedger");
  const ledger = await MockLedger.deploy();
  await ledger.waitForDeployment();

  // LMSRMarketMaker(governor, ledger)
  const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
  const amm = await LMSR.deploy(governor.address, await ledger.getAddress());
  await amm.waitForDeployment();

  // Seed positions
  const marketId = 1;
  const posA = 101;
  const posB = 102;

  await ledger.seedPosition(marketId, posA);
  await ledger.seedPosition(marketId, posB);

  // 50/50 priors, no reserve, not expanding
  const InitialPosition = [
    { positionId: posA, r: ethers.parseEther("0.5") },
    { positionId: posB, r: ethers.parseEther("0.5") },
  ];

  const liabilityUSDC = usdcUnits(1_000); // 1000 USDC exposure

  await amm
    .connect(governor)
    .initMarket(
      marketId,
      InitialPosition,
      liabilityUSDC,
      0,
      false
    );

  return { owner, trader, governor, amm, ledger, marketId, posA, posB, liabilityUSDC };
}

/**
 * Infer an effective b from a single trade using:
 *   usdcIn ≈ b * ln(Z_after / Z_before)
 * → b ≈ usdcIn / ln(Z_after / Z_before)
 *
 * This doesn’t assume anything about how b was computed on-chain; it just
 * checks that the AMM’s cost function is internally Hansen-consistent.
 */
function inferBFromTrade({ usdcIn, Zbefore, Zafter }) {
  const zBeforeNum = Number(Zbefore);
  const zAfterNum  = Number(Zafter);

  // Guard: Z must be positive and strictly change
  if (zBeforeNum <= 0 || zAfterNum <= 0) {
    throw new Error("Z values must be positive");
  }

  const ratio = zAfterNum / zBeforeNum;
  // If ratio == 1 (no change), ln(1)=0 → skip
  if (ratio === 1) {
    throw new Error("Z ratio is 1; trade too small to infer b");
  }

  const lnRatio = Math.log(ratio);
  if (!Number.isFinite(lnRatio) || lnRatio === 0) {
    throw new Error("Invalid lnRatio");
  }

  const costNum = Number(usdcIn); // usdcIn is in 1e6, safely < 2^53 here
  return costNum / lnRatio;
}

describe("LMSRMarketMaker – Hanson cost parity", () => {
  let fx;

  beforeEach(async () => {
    fx = await setupLmsr();
  });

  it("buyExactTokens matches Hanson ΔC ≈ b * ln(Z_after/Z_before)", async () => {
    const { amm, marketId, posA } = fx;

    // --- First trade ---
    const t1 = usdcUnits(10);        // 10 tokens
    const maxIn1 = usdcUnits(1_000); // very loose cap

    const Z0 = await amm.getZ(marketId);

    // Static-call for the usdcIn quote
    const usdcIn1 = await amm.applyBuyExactTokens.staticCall(
      marketId,
      posA,
      true,   // isBack
      t1,
      maxIn1
    );

    expect(usdcIn1).to.be.gt(0n);

    // Apply trade for real so Z changes
    await amm.applyBuyExactTokens(
      marketId,
      posA,
      true,
      t1,
      maxIn1
    );

    const Z1 = await amm.getZ(marketId);

    // --- Second trade, from the new state ---
    const t2 = usdcUnits(10);        // same size
    const maxIn2 = usdcUnits(1_000);

    const usdcIn2 = await amm.applyBuyExactTokens.staticCall(
      marketId,
      posA,
      true,
      t2,
      maxIn2
    );
    expect(usdcIn2).to.be.gt(0n);

    await amm.applyBuyExactTokens(
      marketId,
      posA,
      true,
      t2,
      maxIn2
    );

    const Z2 = await amm.getZ(marketId);

    // --- Infer b from both trades and compare ---

    const b1 = inferBFromTrade({
      usdcIn: usdcIn1,
      Zbefore: Z0,
      Zafter: Z1,
    });

    const b2 = inferBFromTrade({
      usdcIn: usdcIn2,
      Zbefore: Z1,
      Zafter: Z2,
    });

    // Sanity: both finite & positive
    expect(b1).to.be.gt(0);
    expect(b2).to.be.gt(0);
    expect(Number.isFinite(b1)).to.equal(true);
    expect(Number.isFinite(b2)).to.equal(true);

    // Relative difference should be reasonably small (e.g. < 5%)
    const relDiff = Math.abs(b1 - b2) / b1;
    expect(relDiff).to.be.lt(0.05);
  });
});
