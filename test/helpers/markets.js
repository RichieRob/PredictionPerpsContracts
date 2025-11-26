// test/helpers/markets.js
const { expect } = require("chai");

// ---------------------------------------------------------
//  Per-account solvency & redeemability helper (you already have this)
// ---------------------------------------------------------
async function expectSolventRedeemability(fx, { account, marketId }) {
  const { ledger } = fx;

  const effMin = await ledger.invariant_effectiveMin(account, marketId);
  expect(effMin).to.be.gte(0n);

  const [netAlloc, redeemable, margin] =
    await ledger.invariant_redeemabilityState(account, marketId);

  // margin = netAlloc - redeemable, should never be negative
  expect(margin).to.be.gte(0n);
  if (redeemable > 0n) {
    expect(netAlloc).to.be.gte(redeemable);
  }

  const okAll = await ledger.invariant_checkSolvencyAllMarkets(account);
  expect(okAll).to.equal(true);
}

// ---------------------------------------------------------
//  Core system invariants + (optional) per-account checks
// ---------------------------------------------------------
async function expectCoreSystemInvariants(
  fx,
  {
    accounts = [],         // list of addresses to check solvency for
    marketId = null,       // if provided, we can also hammer redeemability
    checkRedeemabilityFor = [], // subset of accounts to run redeemability on
  } = {}
) {
  const { ledger } = fx;

  // TVL vs aUSDC
  const [tvl, aBal] = await ledger.invariant_tvl();
  expect(aBal).to.equal(tvl);

  // system balance: TotalMarketsValue + totalFreeCollateral == totalValueLocked
  const [lhs, rhs] = await ledger.invariant_systemBalance();
  expect(lhs).to.equal(rhs);

  // per-account solvency across all markets
  for (const account of accounts) {
    const ok = await ledger.invariant_checkSolvencyAllMarkets(account);
    expect(ok).to.equal(true);
  }

  // optional redeemability hammer per account on a specific market
  if (marketId !== null) {
    for (const account of checkRedeemabilityFor) {
      await expectSolventRedeemability(fx, { account, marketId });
    }
  }
}

module.exports = {
  // core / trading / invariants
  ...require("./markets.core"),
  // gas helpers
  ...require("./markets.gas"),
  // markets & positions metadata
  ...require("./markets.meta"),
  // multi-market helpers
  ...require("./markets.multi"),
  // multi-user helpers
  ...require("./markets.multiuser"),
  expectSolventRedeemability,
  expectCoreSystemInvariants,     // 👈 new
};
