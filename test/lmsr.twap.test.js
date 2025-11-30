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
  await ledger.waitForDeployment(); // NEW: Deploy PositionERC20 and set it const PositionERC20 = await ethers.getContractFactory("PositionERC20"); const positionImpl = await PositionERC20.deploy(await fx.ledger.getAddress()); await positionImpl.waitForDeployment(); await fx.ledger.connect(fx.owner).setPositionERC20Implementation(await positionImpl.getAddress());

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
    ).to.be.reverted;
  });

  it("TWAP matches manual piecewise-constant price integral", async () => {
    const { amm, marketId, posA, owner } = fx;

    // Make trades big enough to move price materially
    const tradeSize = usdc(1_000);   // 1000 units
    const maxIn     = usdc(1_000_000);

    // --- 1) Kick TWAP into the normal regime with an initial trade ---

    await amm
      .connect(owner)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,       // isBack
        tradeSize,
        maxIn
      );

    // Start checkpoint *after* first trade so lastTs != 0 and cumStart is sane
    const [cumStart, tStart] = await amm.twapCurrentCumulative(marketId, posA);

    // --- 2) Build a few long time segments with trades in between ---

    const segments = [];

    // Helper: record current BACK price, then advance time by dt
    async function addSegment(dtSeconds) {
      const price = await amm.getBackPriceWad(marketId, posA); // BigInt [0, 1e18)
      await increaseTime(dtSeconds);
      segments.push({
        dt: BigInt(dtSeconds),
        price, // BigInt
      });
    }

    const DT1 = 1_000;
    const DT2 = 2_000;
    const DT3 = 3_000;

    await addSegment(DT1);

    await amm
      .connect(owner)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,
        tradeSize,
        maxIn
      );

    await addSegment(DT2);

    await amm
      .connect(owner)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,
        tradeSize,
        maxIn
      );

    await addSegment(DT3);

    // --- 3) Final checkpoint + on-chain TWAP ---

    const [cumEnd, tEnd] = await amm.twapCurrentCumulative(marketId, posA);

    const dtTotal = tEnd - tStart; // BigInt
    expect(dtTotal).to.be.gt(0n);

    let manualDen = 0n;
    for (const seg of segments) {
      manualDen += seg.dt;
    }

    const drift = dtTotal > manualDen ? dtTotal - manualDen : manualDen - dtTotal;
    expect(drift).to.be.lte(5n);

    const dCum = cumEnd - cumStart;

    // On-chain WAD-scaled avg: avgWad = dCum * WAD / dtTotal
    const onchainAvgWad = (dCum * WAD) / dtTotal;

    // --- 4) Manual TWAP: Σ p_i * dt_i / Σ dt_i ---

    let manualNum = 0n;
    for (const seg of segments) {
      manualNum += seg.price * seg.dt; // price is WAD, dt is seconds
    }
    const manualAvgWad = manualNum / manualDen;

    // --- 5) Compare on-chain vs manual within a small tolerance ---

    const diff = onchainAvgWad > manualAvgWad
      ? onchainAvgWad - manualAvgWad
      : manualAvgWad - onchainAvgWad;

    const tolerance = manualAvgWad / 1_000n + 1n; // ~0.1% + 1 wei

    // ---- LOG DETAILS ----
    const relBps = manualAvgWad === 0n
      ? 0n
      : (diff * 10_000n) / manualAvgWad; // basis points (1e-4)

    console.log("\n[TWAP debug]");
    console.log("  dtTotal (sec):      ", dtTotal.toString());
    console.log("  intended dt (sec):  ", manualDen.toString());
    console.log("  drift (sec):        ", drift.toString());
    console.log("  manualAvgWad:       ", manualAvgWad.toString());
    console.log("  onchainAvgWad:      ", onchainAvgWad.toString());
    console.log("  diff (WAD):         ", diff.toString());
    console.log("  rel error (bps):    ", relBps.toString());
    console.log("  tolerance (WAD):    ", tolerance.toString());

    expect(diff).to.be.lte(tolerance);
  });


  
});
