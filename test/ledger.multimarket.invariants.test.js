// test/ledger.multi-market.invariants.test.js
const { expect } = require("chai");
const { usdc } = require("./helpers/core");
const {
  setupMultiMarketFixture,
  depositAndCheckFlatMulti,
  expectMultiMarketInvariantsAfterTrades,
} = require("./helpers/markets");

describe("MarketMakerLedger – multi-market invariants", function () {
  let fx; // { owner, trader, usdc, aUSDC, ledger, flatMM, marketId1, marketId2, positionId1, positionId2 }

  beforeEach(async () => {
    fx = await setupMultiMarketFixture();
  });

  it("maintains per-market + system invariants after trading in two markets", async () => {
    const TRADER_DEPOSIT = usdc("10000");
    await depositAndCheckFlatMulti(fx, TRADER_DEPOSIT);

    const BUY_M1_TOKENS = usdc("100");
    const BUY_M2_TOKENS = usdc("60");
    const MAX_USDC_IN   = usdc("10000");

    // trades in both markets
    await fx.ledger.connect(fx.trader).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId1,
      fx.positionId1,
      true,
      BUY_M1_TOKENS,
      MAX_USDC_IN
    );

    await fx.ledger.connect(fx.trader).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId2,
      fx.positionId2,
      true,
      BUY_M2_TOKENS,
      MAX_USDC_IN
    );

    await expectMultiMarketInvariantsAfterTrades(fx, {
      totalDeposit: TRADER_DEPOSIT,
    });
  });

  it("keeps TotalMarketsValue equal to the sum of per-market marketValue", async () => {
    const TRADER_DEPOSIT = usdc("8000");
    await depositAndCheckFlatMulti(fx, TRADER_DEPOSIT);

    const BUY_M1_TOKENS = usdc("50");
    const BUY_M2_TOKENS = usdc("80");
    const MAX_USDC_IN   = usdc("8000");

    await fx.ledger.connect(fx.trader).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId1,
      fx.positionId1,
      true,
      BUY_M1_TOKENS,
      MAX_USDC_IN
    );

    await fx.ledger.connect(fx.trader).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId2,
      fx.positionId2,
      true,
      BUY_M2_TOKENS,
      MAX_USDC_IN
    );

    const markets = await fx.ledger.getMarkets();
    let sumMarketValues = 0n;

    for (const mid of markets) {
      const mv = await fx.ledger.getMarketValue(mid);
      sumMarketValues += mv;
    }

    const totalMarketsValue = await fx.ledger.getTotalMarketsValue();
    expect(totalMarketsValue).to.equal(sumMarketValues);
  });
});
