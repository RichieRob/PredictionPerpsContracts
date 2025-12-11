// test/helpers/markets.meta.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * Creates a market with the given details and ensures the DMM is allowed.
 * Returns the created marketId.
 */
async function createMarketWithDetails(
  fx,
  {
    name,
    ticker,
    dmmAddress,
    iscAmount = 0n,
    doesResolve = false,
    oracle = ethers.ZeroAddress,
    oracleParams = "0x",
    feeBps = 0,
    marketCreator,          // optional override
    feeWhitelistAccounts = [],
    hasWhitelist = false,
  }
) {
  const { ledger, owner } = fx;
  const creator = marketCreator || owner.address;

  // Ensure DMM is allowed (if non-zero)
  if (dmmAddress && dmmAddress !== ethers.ZeroAddress) {
    await ledger.connect(owner).allowDMM(dmmAddress, true);
  }

  const tx = await ledger.connect(owner).createMarket(
    name,
    ticker,
    dmmAddress,
    iscAmount,
    doesResolve,
    oracle,
    oracleParams,
    feeBps,
    creator,
    feeWhitelistAccounts,
    hasWhitelist
  );
  await tx.wait();

  const markets = await ledger.getMarkets();
  // Most tests use a fresh fx per file, but be defensive:
  const marketId = markets[markets.length - 1];

  // Verify stored details
  const [onChainName, onChainTicker] = await ledger.getMarketDetails(marketId);
  expect(onChainName).to.equal(name);
  expect(onChainTicker).to.equal(ticker);

  return marketId;
}

/**
 * Batch meta check:
 *  - correct number of positions
 *  - base name/symbol (no Back/Lay prefix)
 *  - plus a Back+Lay sanity check on the first position
 */
async function expectPositionsBatchMetaForMarket(
  fx,
  {
    marketId,
    positions,    // [{ name, ticker }, ...]
    marketName,
    marketTicker,
  }
) {
  const { ledger, owner } = fx;

  // ---- Create positions + ERC20 mirrors (Back & Lay) ----
  const tx = await ledger.connect(owner).createPositions(marketId, positions);
  await tx.wait();

  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(positions.length);

  // Base meta for all positions
  for (let i = 0; i < positionIds.length; i++) {
    const pid = positionIds[i];
    const p   = positions[i];

    const baseName   = await ledger.erc20BaseName(marketId, pid);
    const baseSymbol = await ledger.erc20BaseSymbol(marketId, pid);

    expect(baseName).to.equal(`${p.name} in ${marketName}`);
    expect(baseSymbol).to.equal(`${p.ticker}-${marketTicker}`);
  }

  // Extra Back/Lay sanity for the first position
  if (positionIds.length > 0) {
    const pid0 = positionIds[0];
    const p0   = positions[0];

    const backName   = await ledger.erc20NameForSide(marketId, pid0, true);
    const backSymbol = await ledger.erc20SymbolForSide(marketId, pid0, true);
    const layName    = await ledger.erc20NameForSide(marketId, pid0, false);
    const laySymbol  = await ledger.erc20SymbolForSide(marketId, pid0, false);

    expect(backName).to.equal(`Back ${p0.name} in ${marketName}`);
    expect(backSymbol).to.equal(`B-${p0.ticker}-${marketTicker}`);

    expect(layName).to.equal(`Lay ${p0.name} in ${marketName}`);
    expect(laySymbol).to.equal(`L-${p0.ticker}-${marketTicker}`);
  }
}


/**
 * Static meta + zero balances:
 *  - checks base naming,
 *  - ERC20 Back & Lay names/symbols,
 *  - totalSupply == 0 for both mirrors (no ISC, no trades),
 *  - balances == 0 for owner + trader.
 */
async function expectPositionsStaticMetaAndZeroBalances(
  fx,
  {
    marketId,
    teams,       // [{ name, ticker }, ...]
    marketName,
    marketTicker,
  }
) {
  const { ledger, owner, trader } = fx;

  // ---- Create positions + ERC20 mirrors (Back & Lay) ----
  const tx = await ledger.connect(owner).createPositions(marketId, teams);
  await tx.wait();

  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(teams.length);

  for (let i = 0; i < positionIds.length; i++) {
    const pid = positionIds[i];
    const t   = teams[i];

    // Base naming from ledger (no Back/Lay prefix)
    const baseName   = await ledger.erc20BaseName(marketId, pid);
    const baseSymbol = await ledger.erc20BaseSymbol(marketId, pid);

    expect(baseName).to.equal(`${t.name} in ${marketName}`);
    expect(baseSymbol).to.equal(`${t.ticker}-${marketTicker}`);

    // ERC20 clones wired for Back & Lay
    const backTokenAddr = await ledger.getBackPositionERC20(marketId, pid);
    const layTokenAddr  = await ledger.getLayPositionERC20(marketId, pid);

    expect(backTokenAddr).to.properAddress;
    expect(layTokenAddr).to.properAddress;

    const BackToken = await ethers.getContractAt("PositionERC20", backTokenAddr);
    const LayToken  = await ethers.getContractAt("PositionERC20", layTokenAddr);

    const backName   = await BackToken.name();
    const backSymbol = await BackToken.symbol();
    const layName    = await LayToken.name();
    const laySymbol  = await LayToken.symbol();

    // 🔵 Back expectations
    expect(backName).to.equal(`Back ${t.name} in ${marketName}`);
    expect(backSymbol).to.equal(`B-${t.ticker}-${marketTicker}`);

    // 🔴 Lay expectations
    expect(layName).to.equal(`Lay ${t.name} in ${marketName}`);
    expect(laySymbol).to.equal(`L-${t.ticker}-${marketTicker}`);

    // Zero supply & balances (no ISC, no trades in these tests)
    const backSupply = await BackToken.totalSupply();
    const laySupply  = await LayToken.totalSupply();

    expect(backSupply).to.equal(0n);
    expect(laySupply).to.equal(0n);

    const addrsToCheck = [owner.address, trader.address];
    for (const addr of addrsToCheck) {
      const bBal = await BackToken.balanceOf(addr);
      const lBal = await LayToken.balanceOf(addr);

      expect(bBal).to.equal(0n);
      expect(lBal).to.equal(0n);
    }
  }
}


module.exports = {
  createMarketWithDetails,
  expectPositionsBatchMetaForMarket,
  expectPositionsStaticMetaAndZeroBalances,
};
