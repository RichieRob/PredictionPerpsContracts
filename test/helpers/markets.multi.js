// test/helpers/markets.multi.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, mintAndDeposit } = require("./core");

// ---------------------------------------------------------
//  Multi-market fixture: 2 markets, 1 YES each
// ---------------------------------------------------------

async function setupMultiMarketFixture() {
  // fx: { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  const fx = await deployCore();
  const { ledger } = fx;

  // Flat DMM
  const FlatMockMarketMaker = await ethers.getContractFactory(
    "FlatMockMarketMaker"
  );
  fx.flatMM = await FlatMockMarketMaker.deploy();
  await fx.flatMM.waitForDeployment();

  await ledger.allowDMM(await fx.flatMM.getAddress(), true);

  const ISC_LINE_1 = usdc("100000");
  const ISC_LINE_2 = usdc("50000");

  // Market 1
  await ledger.createMarket(
    "MultiMarket One",
    "MM1",
    await fx.flatMM.getAddress(),
    ISC_LINE_1,
    false,
    ethers.ZeroAddress,
    "0x"
  );

  // Market 2
  await ledger.createMarket(
    "MultiMarket Two",
    "MM2",
    await fx.flatMM.getAddress(),
    ISC_LINE_2,
    false,
    ethers.ZeroAddress,
    "0x"
  );

  const markets = await ledger.getMarkets();
  expect(markets.length).to.equal(2);

  fx.marketId1 = markets[0];
  fx.marketId2 = markets[1];

  // YES in each market
  const posMeta1 = [{ name: "YES-1", ticker: "Y1" }];
  await (await ledger.createPositions(fx.marketId1, posMeta1)).wait();
  const posIds1 = await ledger.getMarketPositions(fx.marketId1);
  fx.positionId1 = posIds1[0];

  const posMeta2 = [{ name: "YES-2", ticker: "Y2" }];
  await (await ledger.createPositions(fx.marketId2, posMeta2)).wait();
  const posIds2 = await ledger.getMarketPositions(fx.marketId2);
  fx.positionId2 = posIds2[0];

  return fx;
}

// ---------------------------------------------------------
//  Deposit helper (with TVL check)
// ---------------------------------------------------------

async function depositAndCheckFlatMulti(fx, amount) {
  const { usdc, ledger, trader } = fx;

  await mintAndDeposit({
    usdc,
    ledger,
    trader,
    amount,
  });

  const [tvlBefore, aUSDCBefore] = await fx.ledger.invariant_tvl();
  expect(tvlBefore).to.equal(aUSDCBefore);
  expect(tvlBefore).to.equal(amount);

  return { tvlBefore, aUSDCBefore };
}

// ---------------------------------------------------------
//  Multi-market invariants after trading in both markets
// ---------------------------------------------------------

async function expectMultiMarketInvariantsAfterTrades(fx, { totalDeposit }) {
  const { ledger, flatMM, trader, marketId1, marketId2 } = fx;

  // per-market accounting
  const [lhsM1, rhsM1] = await ledger.invariant_marketAccounting(marketId1);
  const [lhsM2, rhsM2] = await ledger.invariant_marketAccounting(marketId2);

  expect(lhsM1).to.equal(rhsM1);
  expect(lhsM2).to.equal(rhsM2);

  // system balance sheet
  const [lhsSys, rhsSys] = await ledger.invariant_systemBalance();
  expect(lhsSys).to.equal(rhsSys);

  // TVL vs aUSDC
  const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
  expect(aUSDCAfter).to.equal(tvlAfter);
  expect(tvlAfter).to.equal(totalDeposit);

  // solvency across *all* markets
  const okTrader = await ledger.invariant_checkSolvencyAllMarkets(
    trader.address
  );
  expect(okTrader).to.equal(true);

  const okDMM = await ledger.invariant_checkSolvencyAllMarkets(
    await flatMM.getAddress()
  );
  expect(okDMM).to.equal(true);
}

module.exports = {
  setupMultiMarketFixture,
  depositAndCheckFlatMulti,
  expectMultiMarketInvariantsAfterTrades,
};
