// test/ledger.multi-user.ppusdc.test.js
const { usdc } = require("./helpers/core");
const {
  setupMultiUserTwoPositionFixture,
  multiUserDeposits,
  expectMultiUserPpUsdcAndErc20Mirrors,
} = require("./helpers/markets");

describe("MarketMakerLedger – multi-user trading & ppUSDC mirrors", function () {
  let fx; // { owner, alice, bob, usdc, aUSDC, ppUSDC, ledger, flatMM, marketId, posA, posB, tokenA, tokenB }

  beforeEach(async () => {
    fx = await setupMultiUserTwoPositionFixture();
  });

  it("keeps ppUSDC + ERC20 mirrors correct after multi-user ppUSDC-backed buys", async () => {
    const DEPOSIT_ALICE = usdc("10000");
    const DEPOSIT_BOB   = usdc("8000");

    await multiUserDeposits(fx, {
      aliceDeposit: DEPOSIT_ALICE,
      bobDeposit:   DEPOSIT_BOB,
    });

    const MAX_IN_ALICE = usdc("5000");
    const MAX_IN_BOB   = usdc("4000");

    const mm = await fx.flatMM.getAddress();

    // ── Alice buys A then B (BACK)
    await fx.ledger.connect(fx.alice).buyExactTokens(
      mm,
      fx.marketId,
      fx.posA,
      true,              // isBack
      usdc("50"),        // number of BACK shares (using 6dp helper for scale)
      MAX_IN_ALICE       // max ppUSDC in
    );

    await fx.ledger.connect(fx.alice).buyExactTokens(
      mm,
      fx.marketId,
      fx.posB,
      true,              // isBack
      usdc("30"),
      MAX_IN_ALICE
    );

    // ── Bob buys B then A (BACK)
    await fx.ledger.connect(fx.bob).buyExactTokens(
      mm,
      fx.marketId,
      fx.posB,
      true,
      usdc("40"),
      MAX_IN_BOB
    );

    await fx.ledger.connect(fx.bob).buyExactTokens(
      mm,
      fx.marketId,
      fx.posA,
      true,
      usdc("20"),
      MAX_IN_BOB
    );

    // Final invariant: ppUSDC + PositionERC20 mirrors vs ledger internals
    await expectMultiUserPpUsdcAndErc20Mirrors(fx);
  });
});
