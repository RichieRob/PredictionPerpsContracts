// test/helpers/deposits.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  usdc,
  deployCore,
  depositFromTrader,
  expectFlatLedgerForTrader,
  EMPTY_PERMIT,
} = require("./core");

// ---------------------------------------------------------
//  Core fixture
// ---------------------------------------------------------

async function setupDepositFixture() {
  const fx = await deployCore();

  // Fund trader with some USDC for all tests here (still fine)
  await fx.usdc.mint(fx.trader.address, usdc("1000"));

  return fx;
}

// ---------------------------------------------------------
//  Simple "flat" scenarios (no fees, no trades)
// ---------------------------------------------------------

async function depositAndCheckFlat(fx, amount) {
  const { ledger, usdc: usdcToken, trader, aUSDC, ppUSDC } = fx;

  // 🔧 Ensure the trader actually has the USDC we're about to deposit
  await usdcToken.mint(trader.address, amount);

  await depositFromTrader({
    ledger,
    usdc: usdcToken,
    trader,
    amount,
  });

  await expectFlatLedgerForTrader({
    ledger,
    aUSDC,
    ppUSDC,
    trader,
    expected: amount,
  });
}

/**
 * - deposits `depositAmount`
 * - withdraws `withdrawAmount` to trader
 * - checks:
 *    • wallet delta == withdrawAmount
 *    • ledger / ppUSDC state == depositAmount - withdrawAmount
 */
async function withdrawAndCheckFlat(fx, { depositAmount, withdrawAmount }) {
  const { ledger, trader, usdc: usdcToken, aUSDC, ppUSDC } = fx;

  // 1) Start from a clean flat state
  await depositAndCheckFlat(fx, depositAmount);

  // 2) Withdraw and measure wallet delta
  const before = await usdcToken.balanceOf(trader.address);

  await ledger.connect(trader).withdraw(withdrawAmount, trader.address);

  const after = await usdcToken.balanceOf(trader.address);
  expect(after - before).to.equal(withdrawAmount);

  // 3) Expect a new flat state with reduced amount
  const expected = depositAmount - withdrawAmount;

  await expectFlatLedgerForTrader({
    ledger,
    aUSDC,
    ppUSDC,
    trader,
    expected,
  });
}

// ---------------------------------------------------------
//  Fee helpers
// ---------------------------------------------------------

async function enableFee(fx, bps) {
  const { ledger, owner, feeRecipient } = fx;
  await ledger
    .connect(owner)
    .setFeeConfig(feeRecipient.address, bps, true);
}

/**
 * Enables fee, deposits, then asserts all fee-related balances:
 * - fee recipient got `feeExpected`
 * - ledger TVL / aUSDC / freeCollateral / ppUSDC == `netExpected`
 */
async function expectFeeDepositState(fx, { amount, bps }) {
  const {
    ledger,
    usdc: usdcToken,
    trader,
    aUSDC,
    ppUSDC,
    feeRecipient,
  } = fx;

  await enableFee(fx, bps);

  await usdcToken
    .connect(trader)
    .approve(await ledger.getAddress(), amount);

  await ledger.connect(trader).deposit(
    trader.address,
    amount,
    0n,      // minUSDCDeposited
    0,       // mode = allowance
    EMPTY_PERMIT,
    "0x"
  );

  const feeExpected = (amount * BigInt(bps)) / 10_000n;
  const netExpected = amount - feeExpected;

  const tvl = await ledger.getTotalValueLocked();
  const aBalLedger = await aUSDC.balanceOf(await ledger.getAddress());
  const aBalFee = await aUSDC.balanceOf(feeRecipient.address);
  const freeTrader = await ledger.realFreeCollateral(trader.address);
  const totalFree = await ledger.realTotalFreeCollateral();
  const ppBal = await ppUSDC.balanceOf(trader.address);
  const ppTotal = await ppUSDC.totalSupply();

  expect(aBalFee).to.equal(feeExpected);
  expect(aBalLedger).to.equal(netExpected);
  expect(tvl).to.equal(netExpected);
  expect(freeTrader).to.equal(netExpected);
  expect(totalFree).to.equal(netExpected);
  expect(ppBal).to.equal(netExpected);
  expect(ppTotal).to.equal(netExpected);
}

/**
 * Sets a big fee, then checks deposit reverts when `recorded < minUSDCDeposited`.
 */
async function expectDepositBelowMinReverts(fx, { amount, bps }) {
  const { ledger, usdc: usdcToken, trader, owner, feeRecipient } = fx;

  await ledger
    .connect(owner)
    .setFeeConfig(feeRecipient.address, bps, true);

  await usdcToken
    .connect(trader)
    .approve(await ledger.getAddress(), amount);

  const minUSDCDeposited = amount; // but recorded < amount

  await expect(
    ledger.connect(trader).deposit(
      trader.address,
      amount,
      minUSDCDeposited,
      0,
      EMPTY_PERMIT,
      "0x"
    )
  ).to.be.reverted;
}

// ---------------------------------------------------------
//  Withdraw constraint helpers
// ---------------------------------------------------------

async function expectWithdrawTooMuchReverts(fx, { baseAmount }) {
  const { ledger, trader } = fx;

  await depositAndCheckFlat(fx, baseAmount);

  const tooMuch = baseAmount + usdc("1");

  await expect(
    ledger.connect(trader).withdraw(tooMuch, trader.address)
  ).to.be.reverted;
}

async function expectWithdrawToZeroReverts(fx, { baseAmount }) {
  const { ledger, trader } = fx;

  await depositAndCheckFlat(fx, baseAmount);

  await expect(
    ledger.connect(trader).withdraw(baseAmount, ethers.ZeroAddress)
  ).to.be.reverted;
}

// ---------------------------------------------------------
//  TVL vs aUSDC invariant helper
// ---------------------------------------------------------

async function expectTvlEqABal(fx) {
  const { ledger, aUSDC } = fx;
  const tvl = await ledger.getTotalValueLocked();
  const aBal = await aUSDC.balanceOf(await ledger.getAddress());
  expect(tvl).to.equal(aBal);
  return { tvl, aBal };
}

/**
 * Scenario:
 *  - deposit 100 (flat check)
 *  - deposit +10
 *  - withdraw 50
 *  - assert TVL == aUSDC balance
 */
async function scenarioMultiDepositWithdrawKeepsTvlEqABal(fx) {
  const { ledger, trader, usdc: usdcToken } = fx;

  // 1) First deposit with full flat checks
  await depositAndCheckFlat(fx, usdc("100"));

  // 2) Second deposit: just add more collateral
  await depositFromTrader({
    ledger,
    usdc: usdcToken,
    trader,
    amount: usdc("10"),
  });

  // 3) Withdraw 50
  await ledger
    .connect(trader)
    .withdraw(usdc("50"), trader.address);

  // 4) TVL invariant
  await expectTvlEqABal(fx);
}

// ---------------------------------------------------------
//  Deposit mirror helper (used in deployment test)
// ---------------------------------------------------------

async function expectDepositMirrorsEverything({
  ledger,
  aUSDC,
  ppUSDC,
  usdcToken,
  aavePool,
  account,
  amount,
}) {
  const ledgerAddr = await ledger.getAddress();
  const poolAddr   = await aavePool.getAddress();

  const tvl         = await ledger.getTotalValueLocked();
  const aBalLedger  = await aUSDC.balanceOf(ledgerAddr);
  const aBalPool    = await aUSDC.balanceOf(poolAddr);
  const freeAccount = await ledger.realFreeCollateral(account.address);
  const totalFree   = await ledger.realTotalFreeCollateral();
  const ppBal       = await ppUSDC.balanceOf(account.address);
  const ppTotal     = await ppUSDC.totalSupply();

  // Ledger TVL and aUSDC mirror
  expect(tvl).to.equal(amount);
  expect(aBalLedger).to.equal(amount);

  // aUSDC should be sitting on the ledger, not the pool (mock behaviour)
  expect(aBalPool).to.equal(0n);

  // Free collateral mirrors
  expect(freeAccount).to.equal(amount);
  expect(totalFree).to.equal(amount);

  // ppUSDC mirrors free collateral
  expect(ppBal).to.equal(amount);
  expect(ppTotal).to.equal(amount);
}

// ---------------------------------------------------------
//  Exports
// ---------------------------------------------------------

module.exports = {
  setupDepositFixture,
  depositAndCheckFlat,
  withdrawAndCheckFlat,
  enableFee,
  expectFeeDepositState,
  expectDepositBelowMinReverts,
  expectWithdrawTooMuchReverts,
  expectWithdrawToZeroReverts,
  expectTvlEqABal,
  scenarioMultiDepositWithdrawKeepsTvlEqABal,
  expectDepositMirrorsEverything,
};
