// test/helpers/markets.js
// ---------------------------------------------------------
//  Per-account solvency & redeemability helper
// ---------------------------------------------------------

const { expect } = require("chai");  // <-- add this


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
  };
  