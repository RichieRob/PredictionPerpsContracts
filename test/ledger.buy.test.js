// test/ledger.buy.test.js
const { expect } = require("chai");
const { usdc } = require("./helpers/core");
const {
  setupMarketFixture,
  traderDepositsAndBuys,
  expectIscLineAndDmmSolvent,
  expectTvlMatchesABal,
} = require("./helpers/markets");
const { withdrawAndCheckFlat } = require("./helpers/deposits");

describe("MarketMakerLedger – buy test", function () {
  let fx; // { owner, trader, usdc, aUSDC, ledger, flatMM, marketId, positionId, ... }

  beforeEach(async () => {
    fx = await setupMarketFixture();
  });

  it("lets a trader deposit and try a buy", async () => {
    const TRADER_DEPOSIT = usdc("1000"); // 1,000 USDC
    const TOKENS_TO_BUY  = usdc("10");   // 10 tokens
    const MAX_USDC_IN    = usdc("1000");

    await traderDepositsAndBuys(fx, {
      depositAmount: TRADER_DEPOSIT,
      tokensToBuy: TOKENS_TO_BUY,
      maxUsdcIn: MAX_USDC_IN,
    });

    // sanity check: freeCollateral down
    const free = await fx.ledger.realFreeCollateral(fx.trader.address);
    expect(free).to.be.lt(TRADER_DEPOSIT);

    // Just make sure the view doesn’t revert
    await fx.ledger.getPositionLiquidity(
      fx.trader.address,
      fx.marketId,
      fx.positionId
    );
  });

  it("maintains ISC line + DMM solvency invariants after a buy", async () => {
    const TRADER_DEPOSIT = usdc("1000");
    const TOKENS_TO_BUY  = usdc("10");
    const MAX_USDC_IN    = usdc("1000");

    // Execute the trade path
    await traderDepositsAndBuys(fx, {
      depositAmount: TRADER_DEPOSIT,
      tokensToBuy: TOKENS_TO_BUY,
      maxUsdcIn: MAX_USDC_IN,
    });

    // Trader lost some freeCollateral
    const traderFree = await fx.ledger.realFreeCollateral(fx.trader.address);
    expect(traderFree).to.be.lt(TRADER_DEPOSIT);

    // ISC line + DMM solvency
    await expectIscLineAndDmmSolvent(fx, {
      expectedIscLine: usdc("100000"), // same as setupMarketFixture
    });
  });

  it("keeps TVL equal to aUSDC balance in the mock after deposit + withdraw", async () => {
    // Just reuse the generic flat deposit/withdraw helper
    await withdrawAndCheckFlat(fx, {
      depositAmount: usdc("1000"),
      withdrawAmount: usdc("500"),
    });

    // And (optionally) double-check via the trading-level TVL helper
    await expectTvlMatchesABal(fx);
  });
});
