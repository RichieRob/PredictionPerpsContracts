// test/helpers/markets.core.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  usdc,
  deployCore,
  mintAndDeposit,
} = require("./core");

// ---------------------------------------------------------
//  Market + DMM fixture
// ---------------------------------------------------------

async function setupMarketFixture() {
  // fx: { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  const fx = await deployCore();
  const { ledger } = fx;

  // 1) Deploy flat market maker
  const FlatMockMarketMaker = await ethers.getContractFactory(
    "FlatMockMarketMaker"
  );
  fx.flatMM = await FlatMockMarketMaker.deploy();
  await fx.flatMM.waitForDeployment();

  // 2) Allow it as DMM
  await ledger.allowDMM(await fx.flatMM.getAddress(), true);

  // 3) Create market with ISC line (pure synthetic)
  const iscAmount = usdc("100000"); // 100k synthetic
  await ledger.createMarket(
    "Test Market",
    "TEST",
    await fx.flatMM.getAddress(),
    iscAmount,
    false,             // doesResolve = false
    ethers.ZeroAddress,
    "0x",
    false
  );

  const markets = await ledger.getMarkets();
  fx.marketId = markets[0];

  // 4) Create a single YES position, capturing ERC20 clone address
  const [positionId, positionToken] =
    await ledger.createPosition.staticCall(fx.marketId, "YES", "YES");

  await ledger.createPosition(fx.marketId, "YES", "YES");

  fx.positionId = positionId;
  fx.positionToken = positionToken;

  return fx;
}

// ---------------------------------------------------------
//  Trading helpers
// ---------------------------------------------------------

async function traderDepositsAndBuys(
  fx,
  { depositAmount, tokensToBuy, maxUsdcIn }
) {
  const { usdc: usdcToken, ledger, trader, flatMM, marketId, positionId } = fx;

  // 1) Fund trader + deposit
  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader,
    amount: depositAmount,
  });

  // 2) Execute buy against flat MM
  await ledger.connect(trader).buyExactTokens(
    await flatMM.getAddress(),
    marketId,
    positionId,
    true,           // isBack
    tokensToBuy,
    maxUsdcIn
  );
}

/**
 * Checks:
 *  - ISC line equals expectedIscLine
 *  - usedISC is within [0, iscLine]
 *  - effectiveMin for DMM >= 0
 */
async function expectIscLineAndDmmSolvent(fx, { expectedIscLine }) {
  const { ledger, flatMM, marketId } = fx;

  const [usedISC, iscLine] = await ledger.invariant_iscWithinLine(marketId);

  expect(iscLine).to.equal(expectedIscLine);
  expect(usedISC).to.be.gte(0n);
  expect(usedISC).to.be.lte(iscLine);

  const effMin = await ledger.invariant_effectiveMin(
    await flatMM.getAddress(),
    marketId
  );

  expect(effMin).to.be.gte(0n);
}

/**
 * TVL == aUSDC balance invariant for current state.
 */
async function expectTvlMatchesABal(fx) {
  const { ledger, aUSDC } = fx;
  const tvl = await ledger.getTotalValueLocked();
  const aBal = await aUSDC.balanceOf(await ledger.getAddress());
  expect(aBal).to.equal(tvl);
  return { tvl, aBal };
}

/**
 * Full ISC + ERC20 mirror + solvency check for the DMM
 * at initial state (no real capital deposited).
 */
async function expectDmmIscMirrorState(fx) {
  const { ledger, flatMM, marketId, positionToken, owner, aUSDC } = fx;

  const dmmAddr    = await flatMM.getAddress();
  const ledgerAddr = await ledger.getAddress();

  // TVL should be zero before any real capital goes in
  const tvl = await ledger.getTotalValueLocked();
  const aUSDCBal = await aUSDC.balanceOf(ledgerAddr);
  expect(tvl).to.equal(0n);
  expect(aUSDCBal).to.equal(0n);

  // ISC invariants: used == 0, line == configured ISC
  const [iscUsed, iscLine] = await ledger.invariant_iscWithinLine(marketId);
  expect(iscUsed).to.equal(0n);

  // ERC20 totalSupply = ISC (no real capital yet)
  const ts = await ledger.erc20TotalSupply(positionToken);
  expect(ts).to.equal(iscLine);

  // DMM should hold the full ISC as created shares initially
  const balDMM    = await ledger.erc20BalanceOf(positionToken, dmmAddr);
  const balOwner  = await ledger.erc20BalanceOf(positionToken, owner.address);
  const balLedger = await ledger.erc20BalanceOf(positionToken, ledgerAddr);

  expect(balDMM).to.equal(iscLine);
  expect(balOwner).to.equal(0n);
  expect(balLedger).to.equal(0n);
  expect(balDMM + balOwner + balLedger).to.equal(ts);

  // DMM is solvent and passes invariants
  const effMin = await ledger.invariant_effectiveMin(dmmAddr, marketId);
  expect(effMin).to.be.gte(0n);

  const [netAlloc, redeemable, margin] =
    await ledger.invariant_redeemabilityState(dmmAddr, marketId);
  expect(margin).to.be.gte(0n);
  if (redeemable > 0n) {
    expect(netAlloc).to.be.gte(redeemable);
  }

  const okAll = await ledger.invariant_checkSolvencyAllMarkets(dmmAddr);
  expect(okAll).to.equal(true);
}

// ---------------------------------------------------------
//  ERC20 mirror + wallet sell flow
// ---------------------------------------------------------

async function expectErc20MirrorsWalletSellFlow(fx) {
  const {
    ledger,
    flatMM,
    trader,      // this is "alice"
    owner,
    positionToken: tokenA,
    marketId,
    positionId: posId,
    usdc: usdcToken,
  } = fx;

  const dmmAddr    = await flatMM.getAddress();
  const ledgerAddr = await ledger.getAddress();

  // --- scenario params ---
  const DEPOSIT     = usdc("10000");
  const TOKENS_BUY  = usdc("50");
  const MAX_USDC_IN = usdc("5000");
  const TOKENS_SELL = usdc("20");

  // 1) Deposit for trader (alice)
  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader,
    amount: DEPOSIT,
  });

  // 2) Alice buys YES from DMM
  await ledger.connect(trader).buyExactTokens(
    await flatMM.getAddress(),
    marketId,
    posId,
    true,           // isBack
    TOKENS_BUY,
    MAX_USDC_IN
  );

  // --- balances before wallet-sell ---
  const tsBefore        = await ledger.erc20TotalSupply(tokenA);
  const balAliceBefore  = await ledger.erc20BalanceOf(tokenA, trader.address);
  const balDmmBefore    = await ledger.erc20BalanceOf(tokenA, dmmAddr);
  const balOwnerBefore  = await ledger.erc20BalanceOf(tokenA, owner.address);
  const balLedgerBefore = await ledger.erc20BalanceOf(tokenA, ledgerAddr);

  const sumBefore =
    balAliceBefore + balDmmBefore + balOwnerBefore + balLedgerBefore;
  expect(tsBefore).to.equal(sumBefore);

  // 3) Alice sells some YES and takes USDC back to wallet
  await ledger.connect(trader).sellExactTokensForUSDCToWallet(
    await flatMM.getAddress(),
    marketId,
    posId,
    true,
    TOKENS_SELL,
    0,              // minUSDCOut
    trader.address
  );

  // --- balances after wallet-sell ---
  const tsAfter        = await ledger.erc20TotalSupply(tokenA);
  const balAliceAfter  = await ledger.erc20BalanceOf(tokenA, trader.address);
  const balDmmAfter    = await ledger.erc20BalanceOf(tokenA, dmmAddr);
  const balOwnerAfter  = await ledger.erc20BalanceOf(tokenA, owner.address);
  const balLedgerAfter = await ledger.erc20BalanceOf(tokenA, ledgerAddr);

  // No phantom balances for owner/ledger
  expect(balOwnerAfter).to.equal(0n);
  expect(balLedgerAfter).to.equal(0n);

  // Sum of balances must equal totalSupply
  const sumAfter =
    balAliceAfter + balDmmAfter + balOwnerAfter + balLedgerAfter;
  expect(tsAfter).to.equal(sumAfter);

  // Directional sanity
  expect(balAliceAfter).to.be.lte(balAliceBefore);
  expect(balDmmAfter).to.be.gte(balDmmBefore);

  // TVL invariant still holds
  const [tvl, aUSDCBal] = await ledger.invariant_tvl();
  expect(tvl).to.equal(aUSDCBal);

  // DMM still passes solvency/redeemability checks
  const effMin = await ledger.invariant_effectiveMin(dmmAddr, marketId);
  expect(effMin).to.be.gte(0n);

  const [netAlloc, redeemable, margin] =
    await ledger.invariant_redeemabilityState(dmmAddr, marketId);
  expect(margin).to.be.gte(0n);
  if (redeemable > 0n) {
    expect(netAlloc).to.be.gte(redeemable);
  }

  const okAll = await ledger.invariant_checkSolvencyAllMarkets(dmmAddr);
  expect(okAll).to.equal(true);
}

// ---------------------------------------------------------
//  Invariants after a trade
// ---------------------------------------------------------

async function expectInvariantsAfterTrade(fx, { totalDeposit, expectedIscLine }) {
  const { ledger, flatMM, trader, marketId } = fx;

  const dmmAddr = await flatMM.getAddress();

  // 1) Market accounting: marketValue == MarketUSDCSpent - Redemptions
  const [lhsMarket, rhsMarket] = await ledger.invariant_marketAccounting(
    marketId
  );
  expect(lhsMarket).to.equal(rhsMarket);

  // 2) System balance sheet:
  const [lhsSys, rhsSys] = await ledger.invariant_systemBalance();
  expect(lhsSys).to.equal(rhsSys);

  // 3) TVL vs aUSDC balance (mock: no interest, so equality)
  const [tvl, aUSDCBal] = await ledger.invariant_tvl();
  expect(aUSDCBal).to.equal(tvl);
  expect(tvl).to.equal(totalDeposit);

  // 4) ISC invariant: used ISC within the line
  const [usedISC, iscLine] = await ledger.invariant_iscWithinLine(marketId);
  expect(iscLine).to.equal(expectedIscLine);
  expect(usedISC).to.be.gte(0n);
  expect(usedISC).to.be.lte(iscLine);

  // 5) DMM solvency: effective min-shares >= 0
  const effMinDMM = await ledger.invariant_effectiveMin(dmmAddr, marketId);
  expect(effMinDMM).to.be.gte(0n);

  // 6) DMM redeemability: netAlloc >= redeemable, margin >= 0
  const [netAllocDMM, redeemableDMM, marginDMM] =
    await ledger.invariant_redeemabilityState(dmmAddr, marketId);

  expect(marginDMM).to.be.gte(0n);
  if (redeemableDMM > 0n) {
    expect(netAllocDMM).to.be.gte(redeemableDMM);
  }

  // 7) Trader redeemability: netAlloc >= redeemable, margin >= 0
  const [netAllocTrader, redeemableTrader, marginTrader] =
    await ledger.invariant_redeemabilityState(trader.address, marketId);

  expect(marginTrader).to.be.gte(0n);
  if (redeemableTrader > 0n) {
    expect(netAllocTrader).to.be.gte(redeemableTrader);
  }
}

module.exports = {
  setupMarketFixture,
  traderDepositsAndBuys,
  expectIscLineAndDmmSolvent,
  expectTvlMatchesABal,
  expectDmmIscMirrorState,
  expectErc20MirrorsWalletSellFlow,
  expectInvariantsAfterTrade,
};
