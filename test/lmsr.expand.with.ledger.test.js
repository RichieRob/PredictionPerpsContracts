// test/lmsr.expand.with.ledger.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("LMSR + MarketMakerLedger – expansion from reserve", () => {
  let fx;        // core fixture: { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let amm;       // LMSRMarketMaker
  let marketId;
  let posA, posB, posC;

  const WAD = ethers.parseEther("1");

  async function setupLmsrWithLedger() {
    fx = await deployCore();
    const { owner, ledger } = fx;

    // 1) Deploy LMSR AMM (governor = owner, ledger = real ledger)
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    amm = await LMSR.deploy(owner.address, await ledger.getAddress());
    await amm.waitForDeployment();

    // 2) Allow LMSR as DMM
    await ledger.connect(owner).allowDMM(await amm.getAddress(), true);

    // 3) Create market with ISC line so DMM uses synthetic capital, no real deposit
    const iscAmount = usdc("100000"); // 100k synthetic
    await ledger.createMarket(
      "LMSR Expansion Market",
      "LMSREXP",
      await amm.getAddress(),
      iscAmount,
      false,               // doesResolve
      ethers.ZeroAddress,  // oracle
      "0x"
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // 4) Create 3 positions in the ledger
    //    A, B will be initial; C only becomes tradable after splitFromReserve.
    let tx, receipt;

    tx = await ledger.createPosition(marketId, "Outcome A", "A");
    receipt = await tx.wait();
    const [posAId] = await ledger.getMarketPositions(marketId);
    posA = posAId;

    tx = await ledger.createPosition(marketId, "Outcome B", "B");
    receipt = await tx.wait();
    const posIdsAfterB = await ledger.getMarketPositions(marketId);
    posB = posIdsAfterB[1];

    tx = await ledger.createPosition(marketId, "Outcome C", "C");
    receipt = await tx.wait();
    const posIdsAfterC = await ledger.getMarketPositions(marketId);
    posC = posIdsAfterC[2];

    // 5) Init LMSR with A/B + reserve, expanding = true
    //    Priors: A = 0.4, B = 0.4, reserve = 0.2
    const priors = [
      { positionId: posA, r: ethers.parseEther("0.4") },
      { positionId: posB, r: ethers.parseEther("0.4") },
    ];
    const reserve0      = ethers.parseEther("0.2");
    const liabilityUSDC = 1_000_000n * 1000n; // 1000 USDC in 1e6 units

    await amm
      .connect(owner)
      .initMarket(
        marketId,
        priors,
        liabilityUSDC,
        reserve0,
        true   // isExpanding
      );
  }

  beforeEach(async () => {
    await setupLmsrWithLedger();
  });

  it("keeps S/Z constant and rebalances reserve → new outcome", async () => {
    const G = WAD; // initMarket sets G = 1e18

    const Z_before = await amm.getZ(marketId);
    const S_before = Z_before / G;

    const pA_before   = await amm.getBackPriceWad(marketId, posA);
    const pB_before   = await amm.getBackPriceWad(marketId, posB);
    const pRes_before = await amm.getReservePriceWad(marketId);

    // Split 50% of reserve into C
    const alpha = ethers.parseEther("0.5");
    await amm
      .connect(fx.owner)
      .splitFromReserve(marketId, posC, alpha);

    const Z_after = await amm.getZ(marketId);
    const S_after = Z_after / G;

    const pA_after   = await amm.getBackPriceWad(marketId, posA);
    const pB_after   = await amm.getBackPriceWad(marketId, posB);
    const pC_after   = await amm.getBackPriceWad(marketId, posC);
    const pRes_after = await amm.getReservePriceWad(marketId);

    // S (hence Z) constant
    expect(S_after).to.equal(S_before);

    // Existing outcomes unchanged
    expect(pA_after).to.equal(pA_before);
    expect(pB_after).to.equal(pB_before);

    // New outcome now has non-zero price, reserve went down
    expect(pC_after).to.be.gt(0n);
    expect(pRes_after).to.be.lt(pRes_before);

    // Sum of prices ≈ 1e18
    const sum = pA_after + pB_after + pC_after + pRes_after;
    expect(sum).to.be.closeTo(WAD, WAD / 1_000_000n);
  });

  it("lets a trader buy the new outcome and keeps ledger invariants", async () => {
    const { trader, ledger, usdc: usdcToken } = fx;

    // 1) Expand: move 50% of reserve into C
    const alpha = ethers.parseEther("0.5");
    await amm
      .connect(fx.owner)
      .splitFromReserve(marketId, posC, alpha);

    // 2) Record price of C before trade
    const pC_beforeTrade = await amm.getBackPriceWad(marketId, posC);

    // 3) Trader deposits capital into ledger
    const TRADER_DEPOSIT = usdc("1000");
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: TRADER_DEPOSIT,
    });

    // 4) Trader buys C via the ledger route using LMSR as DMM
    const TOKENS_TO_BUY = usdc("10");
    const MAX_USDC_IN   = usdc("1000");

    await ledger
      .connect(trader)
      .buyExactTokens(
        await amm.getAddress(),
        marketId,
        posC,
        true,             // isBack
        TOKENS_TO_BUY,
        MAX_USDC_IN
      );

    // 5) Price of C should go up
    const pC_afterTrade = await amm.getBackPriceWad(marketId, posC);
    expect(pC_afterTrade).to.be.gt(pC_beforeTrade);

    // 6) Core system invariants still hold
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, await amm.getAddress()],
      marketId,
      checkRedeemabilityFor: [trader.address],
    });
  });
});
