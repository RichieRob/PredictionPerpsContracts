// test/ledger.redeemability.wallet-flows.test.js

const { expect } = require("chai");
const { usdc, EMPTY_PERMIT, mintAndDeposit } = require("./helpers/core");
const {
  setupMarketFixture,
  expectSolventRedeemability,
} = require("./helpers/markets");

describe("MarketMakerLedger – redeemability with wallet flows", function () {
  let fx; // { owner, trader, usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM, marketId, positionId }

  beforeEach(async () => {
    fx = await setupMarketFixture();
  });

  // fund the DMM with real freeCollateral (owner deposits on its behalf)
  async function depositForDMM(fx, amount) {
    const { owner, usdc: usdcToken, ledger, flatMM } = fx;

    await usdcToken.mint(owner.address, amount);
    await usdcToken
      .connect(owner)
      .approve(await ledger.getAddress(), amount);

    await ledger.connect(owner).deposit(
      await flatMM.getAddress(), // ledger account that gets freeCollateral
      amount,
      0n,
      0,              // mode = allowance
      EMPTY_PERMIT,
      "0x"
    );
  }

  it("preserves solvency & redeemability when selling exact tokens to wallet", async () => {
    const TRADER_DEPOSIT = usdc("5000");
    const BUY_TOKENS     = usdc("100");
    const MAX_USDC_IN    = usdc("5000");
    const SELL_TOKENS    = usdc("40");

    const { trader, ledger, flatMM, marketId, positionId, usdc: usdcToken } = fx;

    // fund trader
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: TRADER_DEPOSIT,
    });

    // build a long position
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      BUY_TOKENS,
      MAX_USDC_IN
    );

    const walletBefore = await usdcToken.balanceOf(trader.address);

    // sell some of that position and withdraw proceeds directly to wallet
    await ledger.connect(trader).sellExactTokensForUSDCToWallet(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      SELL_TOKENS,
      0n,              // minUSDCOut = 0
      trader.address
    );

    const walletAfter = await usdcToken.balanceOf(trader.address);
    expect(walletAfter).to.be.gt(walletBefore);

    // trader invariants via shared helper
    await expectSolventRedeemability(fx, {
      account: trader.address,
      marketId,
    });

    // system level TVL vs aUSDC still consistent
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
    expect(aUSDCAfter).to.equal(tvlAfter);
  });

  it("reverts when a sell-for-USDC would violate DMM redeemability (no DMM capital)", async () => {
    const TRADER_DEPOSIT = usdc("5000");
    const BUY_TOKENS     = usdc("150");
    const MAX_USDC_IN    = usdc("5000");

    const { trader, ledger, flatMM, marketId, positionId, usdc: usdcToken } = fx;

    // fund trader
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: TRADER_DEPOSIT,
    });

    // Trader buys to create a long position against the DMM
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      BUY_TOKENS,
      MAX_USDC_IN
    );

    // With no DMM freeCollateral, this sell-for-USDC would force the DMM into:
    // redeemable(DMM) > netUSDCAllocation(DMM)
    const TARGET_USDC_OUT = usdc("300");
    const MAX_TOKENS_IN   = usdc("400");

    await expect(
      ledger.connect(trader).sellForUSDCToWallet(
        await flatMM.getAddress(),
        marketId,
        positionId,
        true,
        TARGET_USDC_OUT,
        MAX_TOKENS_IN,
        trader.address
      )
    ).to.be.reverted;
  });


});
