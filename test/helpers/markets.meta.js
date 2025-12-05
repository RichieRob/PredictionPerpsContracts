// test/helpers/markets.meta.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * Creates a market with the given details and ensures the DMM is allowed.
 * Returns the created marketId.
 */
async function createMarketWithDetails(fx, {
  name,
  ticker,
  dmmAddress,
  iscAmount = 0n,
}) {
  const { ledger, owner } = fx;

  // Ensure DMM is allowed
  await ledger.connect(owner).allowDMM(dmmAddress, true);

  const tx = await ledger.createMarket(
    name,
    ticker,
    dmmAddress,
    iscAmount,
    false,             // doesResolve
    ethers.ZeroAddress,
    "0x"
  );
  await tx.wait();

  const markets = await ledger.getMarkets();
  expect(markets.length).to.equal(1);

  const marketId = markets[0];

  // Verify stored details
  const [onChainName, onChainTicker] = await ledger.getMarketDetails(marketId);
  expect(onChainName).to.equal(name);
  expect(onChainTicker).to.equal(ticker);

  return marketId;
}

/**
 * Creates positions in batch and checks:
 *  - correct number of positions
 *  - getPositionDetails, erc20Name, erc20Symbol are as expected
 */
async function expectPositionsBatchMetaForMarket(fx, {
  marketId,
  positions,
  marketName,
  marketTicker,
}) {
  const { ledger } = fx;

  await ledger.createPositions(marketId, positions);
  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(positions.length);

  for (let i = 0; i < positionIds.length; i++) {
    const pid = positionIds[i];

    const [posName, posTicker] =
      await ledger.getPositionDetails(marketId, pid);
    expect(posName).to.equal(positions[i].name);
    expect(posTicker).to.equal(positions[i].ticker);

    const symbol   = await ledger.erc20Symbol(marketId, pid);
    const fullName = await ledger.erc20Name(marketId, pid);

    expect(symbol).to.equal(`${positions[i].ticker}-${marketTicker}`);
    expect(fullName).to.equal(`${positions[i].name} in ${marketName}`);
  }
}

/**
 * Creates positions one-by-one using staticCall to discover
 * (positionId, backToken, layToken), then checks for the Back mirror:
 *  - getERC20PositionMeta wiring
 *  - erc20Name / erc20Symbol
 *  - totalSupply == 0, balances == 0 for owner + trader
 */
async function expectPositionsStaticMetaAndZeroBalances(fx, {
  marketId,
  teams,
  marketName,
  marketTicker,
}) {
  const { ledger, owner, trader } = fx;

  const created = [];

  for (const t of teams) {
    const [positionId, backToken, layToken] =
      await ledger.createPosition.staticCall(
        marketId,
        t.name,
        t.ticker
      );

    const tx = await ledger.createPosition(marketId, t.name, t.ticker);
    await tx.wait();

    created.push({ positionId, backToken, layToken, ...t });
  }

  // Sanity: market positions list matches count
  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(teams.length);

  for (let i = 0; i < created.length; i++) {
    const { positionId, backToken, name, ticker } = created[i];

    // 1) ERC20PositionMeta wiring (Back mirror)
    const [
      registered,
      mId,
      pId,
      isBack,
      posName,
      posTicker,
      mName,
      mTicker,
    ] = await ledger.getERC20PositionMeta(backToken);

    expect(registered).to.equal(true);
    expect(mId).to.equal(marketId);
    expect(pId).to.equal(positionId);
    expect(isBack).to.equal(true); // we’re checking the Back token here
    expect(posName).to.equal(name);
    expect(posTicker).to.equal(ticker);
    expect(mName).to.equal(marketName);
    expect(mTicker).to.equal(marketTicker);

    // 2) name / symbol helpers (base, side-agnostic)
    const erc20Name   = await ledger.erc20Name(marketId, positionId);
    const erc20Symbol = await ledger.erc20Symbol(marketId, positionId);

    expect(erc20Name).to.equal(`${name} in ${marketName}`);
    expect(erc20Symbol).to.equal(`${ticker}-${marketTicker}`);

    // 3) supply / balances (no trades yet)
    const totalSupply = await ledger.erc20TotalSupply(backToken);
    const ownerBal    = await ledger.erc20BalanceOf(backToken, owner.address);
    const traderBal   = await ledger.erc20BalanceOf(backToken, trader.address);

    expect(totalSupply).to.equal(0n);
    expect(ownerBal).to.equal(0n);
    expect(traderBal).to.equal(0n);
  }
}

module.exports = {
  createMarketWithDetails,
  expectPositionsBatchMetaForMarket,
  expectPositionsStaticMetaAndZeroBalances,
};
