// test/lmsr.twap.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const WAD = 10n ** 18n;

// ------------------------ helpers ------------------------

function usdc(n) {
  return ethers.parseUnits(String(n), 6);
}

async function increaseTime(seconds) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

async function deployLmsrFixture() {
  const [owner, trader, governor] = await ethers.getSigners();

  // Mock USDC (not really used by AMM, but keeps env consistent)
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdcToken = await MockUSDC.deploy();
  await usdcToken.waitForDeployment();

  // Mock ledger for positionExists()
  const MockLedger = await ethers.getContractFactory("MockLedger");
  const ledger = await MockLedger.deploy();
  await ledger.waitForDeployment();

  // LMSR AMM
  const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
  const amm = await LMSR.deploy(governor.address, await ledger.getAddress());
  await amm.waitForDeployment();

  // Simple 2-outcome market
  const marketId = 1;
  const posA = 101;
  const posB = 102;

  await ledger.seedPosition(marketId, posA);
  await ledger.seedPosition(marketId, posB);

  const initialPositions = [
    { positionId: posA, r: ethers.parseEther("0.5") },
    { positionId: posB, r: ethers.parseEther("0.5") },
  ];

  const liabilityUSDC = 1_000_000n * 1000n;

  await amm
    .connect(governor)
    .initMarket(
      marketId,
      initialPositions,
      liabilityUSDC,
      0,      // reserve0
      false   // isExpanding
    );

  return {
    owner,
    trader,
    governor,
    usdc: usdcToken,
    ledger,
    amm,
    marketId,
    posA,
    posB,
  };
}

// ------------------------ tests ------------------------

describe("LMSRMarketMaker – TWAP", () => {
  let fx;

  beforeEach(async () => {
    fx = await deployLmsrFixture();
  });

  it("cumulative price is monotonic and implied avg price stays in [0,1)", async () => {
    const { amm, marketId, posA, owner } = fx;

    // First checkpoint
    const [cum0, t0] = await amm.twapCurrentCumulative(marketId, posA);

    // Let some time pass and do a trade so state is touched
    await increaseTime(60);

    const tSize1 = usdc(10);
    const maxIn1 = usdc(1_000);

    await amm
      .connect(owner)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,        // isBack
        tSize1,
        maxIn1
      );

    const [cum1, t1] = await amm.twapCurrentCumulative(marketId, posA);

    // More time, no trade
    await increaseTime(90);

    const [cum2, t2] = await amm.twapCurrentCumulative(marketId, posA);

    // --- Monotonic timestamps ---
    expect(t1).to.be.gte(t0);
    expect(t2).to.be.gte(t1);

    // --- Monotonic cumulative values (non-decreasing) ---
    expect(cum1).to.be.gte(cum0);
    expect(cum2).to.be.gte(cum1);

    // --- Implied average price over [t0, t2] in [0,1) ---
    const dtTotal = BigInt(t2 - t0);
    expect(dtTotal).to.be.gt(0n); // sanity

    const dCumTotal = cum2 - cum0;

    // If accumulator is still flat, pAvg = 0; that's allowed.
    const pAvg = dCumTotal / dtTotal;

    expect(pAvg).to.be.gte(0n);
    expect(pAvg).to.be.lt(WAD);
  });

  it("consultFromCheckpoints returns a price in [0,1] for a valid window", async () => {
    const { amm, marketId, posA, governor, owner } = fx;

    // Touch state & time a bit so cumulative actually moves
    const [cum0, t0] = await amm.twapCurrentCumulative(marketId, posA);

    await increaseTime(30);

    await amm
      .connect(owner)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,
        usdc(5),
        usdc(1_000)
      );

    await increaseTime(60);

    const [cum1, t1] = await amm.twapCurrentCumulative(marketId, posA);

    expect(t1).to.be.gt(t0);
    expect(cum1).to.be.gte(cum0);

    const avg = await amm
      .connect(governor)
      .twapConsultFromCheckpoints(cum0, t0, cum1, t1);

    expect(avg).to.be.gte(0n);
    expect(avg).to.be.lte(WAD);
  });

  it("reverts on bad TWAP window (zero dt or non-increasing cumulative)", async () => {
    const { amm, marketId, posA, governor } = fx;

    const [cum, ts] = await amm.twapCurrentCumulative(marketId, posA);

    // Same start & end; your library treats this as an invalid window.
    await expect(
      amm
        .connect(governor)
        .twapConsultFromCheckpoints(cum, ts, cum, ts)
    ).to.be.revertedWith("LMSR: bad TWAP window");
  });
});
