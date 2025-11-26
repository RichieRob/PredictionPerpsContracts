// test/ledger.invariants.after-trade.test.js
const { usdc } = require("./helpers/core");
const {
  setupMarketFixture,
  traderDepositsAndBuys,
  expectInvariantsAfterTrade,
} = require("./helpers/markets");

describe("MarketMakerLedger – invariants after a trade", function () {
  let fx; // { owner, trader, usdc, aUSDC, ledger, flatMM, marketId, positionId, ... }

  beforeEach(async () => {
    fx = await setupMarketFixture();
  });

  it("keeps market accounting, system balance, TVL, ISC line and redeemability invariants after a buy", async () => {
    const TRADER_DEPOSIT = usdc("1000");   // 1,000 USDC
    const TOKENS_TO_BUY  = usdc("10");     // 10 tokens
    const MAX_USDC_IN    = usdc("1000");   // cap cost

    // 1) Execute the trade path
    await traderDepositsAndBuys(fx, {
      depositAmount: TRADER_DEPOSIT,
      tokensToBuy: TOKENS_TO_BUY,
      maxUsdcIn: MAX_USDC_IN,
    });

    // 2) Check all invariants in one place
    await expectInvariantsAfterTrade(fx, {
      totalDeposit: TRADER_DEPOSIT,
      expectedIscLine: usdc("100000"), // same as setupMarketFixture
    });
  });
});
