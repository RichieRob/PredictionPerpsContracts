// test/lmsr.expand.pure.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LMSRMarketMaker – expansion from reserve", () => {
  let owner, ledger, amm;
  let marketId;
  let posA, posB, posC;

  const WAD = ethers.parseEther("1");

  async function setupBaseMarket() {
    [owner] = await ethers.getSigners();

    // 1) Mock ledger
    const MockLedger = await ethers.getContractFactory("MockLedger");
    ledger = await MockLedger.deploy();
    await ledger.waitForDeployment();

    // 2) LMSR AMM
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    amm = await LMSR.deploy(owner.address, await ledger.getAddress());
    await amm.waitForDeployment();

    // 3) Seed positions in mock ledger
    marketId = 1;
    posA = 101;
    posB = 102;
    posC = 103; // will be listed later via splitFromReserve

    await ledger.seedPosition(marketId, posA);
    await ledger.seedPosition(marketId, posB);
    await ledger.seedPosition(marketId, posC);

    // 4) Init market:
    //    A: 0.4, B: 0.4, reserve: 0.2  (already sums to 1e18)
    const priors = [
      { positionId: posA, r: ethers.parseEther("0.4") },
      { positionId: posB, r: ethers.parseEther("0.4") },
    ];
    const reserve0      = ethers.parseEther("0.2");
    const liabilityUSDC = 1_000_000n; // arbitrary positive number

    await amm
      .connect(owner)
      .initMarket(
        marketId,
        priors,
        liabilityUSDC,
        reserve0,
        true     // isExpanding = true, so reserve is meaningful
      );
  }

  it("moves α of reserve into a new outcome and keeps Z (hence S) constant", async () => {
    await setupBaseMarket();

    // G is initialised to 1e18 in initMarket and unchanged here
    const G = ethers.parseEther("1");

    const Z_before = await amm.getZ(marketId);
    const S_before = Z_before / G;

    const alpha = ethers.parseEther("0.5"); // 50% of reserve
    await amm
      .connect(owner)
      .splitFromReserve(marketId, posC, alpha);

    const Z_after = await amm.getZ(marketId);
    const S_after = Z_after / G;

    // S must be constant (Z = G·S, G is constant)
    expect(S_after).to.equal(S_before);

    // Prices should still sum to ~1 (A + B + C + reserve)
    const pA   = await amm.getBackPriceWad(marketId, posA);
    const pB   = await amm.getBackPriceWad(marketId, posB);
    const pC   = await amm.getBackPriceWad(marketId, posC);
    const pRes = await amm.getReservePriceWad(marketId);

    const sum = pA + pB + pC + pRes;
    expect(sum).to.be.closeTo(WAD, WAD / 1_000_000n); // within 1e-6
  });

  it("keeps existing outcome prices, gives new outcome non-zero price, and reduces reserve price", async () => {
    await setupBaseMarket();

    // Prices before split
    const pA_before   = await amm.getBackPriceWad(marketId, posA);
    const pRes_before = await amm.getReservePriceWad(marketId);

    const alpha = ethers.parseEther("0.5");
    await amm
      .connect(owner)
      .splitFromReserve(marketId, posC, alpha);

    // Prices after split
    const pA_after   = await amm.getBackPriceWad(marketId, posA);
    const pC_after   = await amm.getBackPriceWad(marketId, posC);
    const pRes_after = await amm.getReservePriceWad(marketId);

    // New outcome should have non-zero price
    expect(pC_after).to.be.gt(0n);

    // Existing outcome price stays the same (mass came from reserve only)
    expect(pA_after).to.equal(pA_before);

    // Reserve lost some mass → its price should drop
    expect(pRes_after).to.be.lt(pRes_before);

    // Optional sanity: total still ~1
    const sum = pA_after + (await amm.getBackPriceWad(marketId, posB)) + pC_after + pRes_after;
    expect(sum).to.be.closeTo(WAD, WAD / 1_000_000n);
  });
});
