// test/helpers/markets.lmsr.js
const { ethers } = require("hardhat");
const { usdc } = require("./core");

const U = (n) => usdc(String(n));

// hard cap for how many positions we include in initMarket
// after this, we add via listPosition
const MAX_INIT_POSITIONS = 221;
const ONE_WAD = ethers.parseUnits("1", 18); // 1.0 in 18dp

/**
 * Helper: add a batch of positions to an already-initialized LMSR market
 * via listPosition, using the same priorR for each.
 */
async function addPositionsViaListing({ owner, lmsr, marketId, posIds, priorR }) {
  for (const ledgerPositionId of posIds) {
    await lmsr
      .connect(owner)
      .listPosition(marketId, ledgerPositionId, priorR);
  }
}

/**
 * Generic LMSR market creator for tests.
 *
 * For nPositions <= MAX_INIT_POSITIONS:
 *   - behaves like before, but uses integer math for priors (no "too many decimals").
 *
 * For nPositions > MAX_INIT_POSITIONS:
 *   - includes only the first MAX_INIT_POSITIONS in initMarket
 *   - then calls listPosition for the remaining positions with the same priorR
 *
 * @param {object} fx - fixture from deployCore / setupLmsrLedgerFixture
 *   expects: { owner, ledger, lmsr }
 * @param {object} opts
 *   - name
 *   - ticker
 *   - nPositions
 *   - smallMarket (bool)
 *   - iscAmount (default 100_000 USDC)
 *   - liabilityUSDC (default 1_000 USDC)
 *   - maxInitPositions (optional override of MAX_INIT_POSITIONS)
 */
async function createLmsrMarket(fx, opts = {}) {
  const {
    owner,
    ledger,
    lmsr,
  } = fx;

  const {
    name = "Extra Market",
    ticker = "EXTRA",
    nPositions = 2,
    smallMarket = false,
    iscAmount = U(100_000),
    liabilityUSDC = U(1_000),
    maxInitPositions = MAX_INIT_POSITIONS,
  } = opts;

  const lmsrAddr = await lmsr.getAddress();

  // 1) create market
  await ledger.createMarket(
    name,
    ticker,
    lmsrAddr,
    iscAmount,
    false,               // doesResolve
    ethers.ZeroAddress,  // oracle
    "0x"         // smallMarket flag
  );

  const markets = await ledger.getMarkets();
  const marketId = markets[markets.length - 1];

  // 2) create positions
  const allPosIds = [];
  for (let i = 0; i < nPositions; i++) {
    const label = `P${i}`;
    await ledger.createPosition(marketId, label, label);
  }
  const created = await ledger.getMarketPositions(marketId);
  for (const p of created) allPosIds.push(p);

  // 3) LMSR priors

  // how many positions go into initMarket?
  const initCount = Math.min(allPosIds.length, maxInitPositions);
  const initPosIds = allPosIds.slice(0, initCount);
  const extraPosIds = allPosIds.slice(initCount);

  // integer-safe equal prior: 1 / initCount in WAD
  // (we just truncate any remainder; that's fine for tests)
  const r = ONE_WAD / BigInt(initCount);
  const priors = initPosIds.map((positionId) => ({ positionId, r }));

  await lmsr
    .connect(owner)
    .initMarket(
      marketId,
      priors,
      liabilityUSDC,
      0,     // reserve0
      false
    );

  // 4) If we have more positions than we could safely init, list them now
  if (extraPosIds.length > 0) {
    await addPositionsViaListing({
      owner,
      lmsr,
      marketId,
      posIds: extraPosIds,
      priorR: r,
    });
  }

  return {
    marketId,
    posIds: allPosIds,
    priorR: r,
    initCount,
    extraCount: extraPosIds.length,
  };
}

module.exports = {
  createLmsrMarket,
  addPositionsViaListing,
  MAX_INIT_POSITIONS,
};
