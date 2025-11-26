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

  it("keeps ppUSDC + ERC20 mirrors correct after multi-user buys & sells", async () => {
    const DEPOSIT_ALICE = usdc("10000");
    const DEPOSIT_BOB   = usdc("8000");

    await multiUserDeposits(fx, {
      aliceDeposit: DEPOSIT_ALICE,
      bobDeposit:   DEPOSIT_BOB,
    });

    const MAX_IN_ALICE = usdc("5000");
    const MAX_IN_BOB   = usdc("4000");

    // Alice buys A then B
    await fx.ledger.connect(fx.alice).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posA,
      true,
      usdc("50"),
      MAX_IN_ALICE
    );

    await fx.ledger.connect(fx.alice).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posB,
      true,
      usdc("30"),
      MAX_IN_ALICE
    );

    // Bob buys B then A
    await fx.ledger.connect(fx.bob).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posB,
      true,
      usdc("40"),
      MAX_IN_BOB
    );

    await fx.ledger.connect(fx.bob).buyExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posA,
      true,
      usdc("20"),
      MAX_IN_BOB
    );

    // Some sells back into the market
    await fx.ledger.connect(fx.alice).sellExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posA,
      true,
      usdc("10"),
      0
    );

    await fx.ledger.connect(fx.bob).sellExactTokens(
      await fx.flatMM.getAddress(),
      fx.marketId,
      fx.posB,
      true,
      usdc("15"),
      0
    );

    await expectMultiUserPpUsdcAndErc20Mirrors(fx);
  });
});
