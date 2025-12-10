// test/deposit.withdraw.tvl.test.js
const { usdc } = require("./helpers/core");
const {
  setupDepositFixture,
  depositAndCheckFlat,
  withdrawAndCheckFlat,
  // removed: expectFeeDepositState, expectDepositBelowMinReverts
  expectWithdrawTooMuchReverts,
  expectWithdrawToZeroReverts,
  scenarioMultiDepositWithdrawKeepsTvlEqABal,
} = require("./helpers/deposits");

describe("MarketMakerLedger — deposits, withdrawals & TVL", function () {
  let fx; // { owner, trader, feeRecipient, usdc, aUSDC, ppUSDC, ledger, ... }

  beforeEach(async () => {
    fx = await setupDepositFixture();
  });

  describe("basic deposit & withdraw (no fees)", function () {
    it("deposits via allowance and updates freeCollateral, totalFreeCollateral & TVL", async function () {
      await depositAndCheckFlat(fx, usdc("100"));
    });

    it("withdraws back to wallet and keeps TVL == aUSDC balance", async function () {
      await withdrawAndCheckFlat(fx, {
        depositAmount: usdc("100"),
        withdrawAmount: usdc("50"),
      });
    });
  });

  // Old "protocol fee on deposit" tests removed – fees are now HWM on markets,
  // not skims on deposit, so those scenarios no longer apply.

  describe("withdraw constraints", function () {
    it("reverts when withdrawing more than freeCollateral", async function () {
      await expectWithdrawTooMuchReverts(fx, {
        baseAmount: usdc("100"),
      });
    });

    it("reverts when withdrawing to zero address", async function () {
      await expectWithdrawToZeroReverts(fx, {
        baseAmount: usdc("100"),
      });
    });
  });

  describe("TVL vs aUSDC balance invariant (mock Aave, no interest)", function () {
    it("keeps TVL equal to aUSDC balance after multiple deposits & withdrawals", async function () {
      await scenarioMultiDepositWithdrawKeepsTvlEqABal(fx);
    });
  });
});
