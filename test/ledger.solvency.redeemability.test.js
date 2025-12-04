// test/ledger.solvency.edgecases.test.js

const { expect } = require("chai");
const { usdc, mintAndDeposit } = require("./helpers/core");
const {
  setupMarketFixture,
  expectSolventRedeemability,
} = require("./helpers/markets");

describe("MarketMakerLedger – solvency & redeemability edge cases", function () {
  let fx; // { owner, trader, usdc, aUSDC, ledger, flatMM, marketId, positionId }

  beforeEach(async () => {
    fx = await setupMarketFixture();
  });

  it("keeps effMin >= 0 and margin >= 0 after multiple buys", async () => {
    const TRADER_DEPOSIT = usdc("5000");
    const TOKENS_TO_BUY  = usdc("50");

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: TRADER_DEPOSIT,
    });

    // three sequential buys to crank up exposure
    for (let i = 0; i < 3; i++) {
      await fx.ledger.connect(fx.trader).buyExactTokens(
        await fx.flatMM.getAddress(),
        fx.marketId,
        fx.positionId,
        true,              // isBack
        TOKENS_TO_BUY,
        TRADER_DEPOSIT     // generous max ppUSDC in
      );
    }

    // trader solvency / redeemability
    await expectSolventRedeemability(fx, {
      account: fx.trader.address,
      marketId: fx.marketId,
    });
  });

  it("keeps effMin >= 0 and margin >= 0 after buys + partial hedge (opposite side)", async () => {
    const TRADER_DEPOSIT = usdc("5000");
    const BUY_TOKENS     = usdc("100");
    const HEDGE_TOKENS   = usdc("30");
    const MAX_PPUSDC     = usdc("5000");

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: TRADER_DEPOSIT,
    });

    const mm = await fx.flatMM.getAddress();

    // two BACK buys to build a chunky long
    for (let i = 0; i < 2; i++) {
      await fx.ledger.connect(fx.trader).buyExactTokens(
        mm,
        fx.marketId,
        fx.positionId,
        true,          // BACK
        BUY_TOKENS,
        MAX_PPUSDC
      );
    }

    // then a smaller LAY buy as a "partial flatten" / hedge
    await fx.ledger.connect(fx.trader).buyExactTokens(
      mm,
      fx.marketId,
      fx.positionId,
      false,         // LAY (opposite side)
      HEDGE_TOKENS,
      MAX_PPUSDC
    );

    await expectSolventRedeemability(fx, {
      account: fx.trader.address,
      marketId: fx.marketId,
    });
  });

  it("keeps DMM solvent with ISC after trader activity", async () => {
    const TRADER_DEPOSIT = usdc("10000");
    const TOKENS_TO_BUY  = usdc("200");
    const MAX_PPUSDC     = usdc("10000");

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: TRADER_DEPOSIT,
    });

    // hammer the DMM a bit
    for (let i = 0; i < 3; i++) {
      await fx.ledger.connect(fx.trader).buyExactTokens(
        await fx.flatMM.getAddress(),
        fx.marketId,
        fx.positionId,
        true,
        TOKENS_TO_BUY,
        MAX_PPUSDC
      );
    }

    const dmmAddress = await fx.flatMM.getAddress();

    await expectSolventRedeemability(fx, {
      account: dmmAddress,
      marketId: fx.marketId,
    });
  });
});
