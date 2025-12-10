// test/helpers/resolution.gas.js
const { ethers } = require("hardhat");
const { usdc, deployCore, mintAndDeposit } = require("./core");

const U = (n) => usdc(String(n));

/**
 * Build a playground of many resolving markets:
 *
 *  - All markets: doesResolve = true, no DMM, no ISC
 *  - Each market has 2 positions: YES / NO
 *  - Trader buys YES vs a funded MM address in every market
 *
 * Returns:
 *  {
 *    fx,                // core fixture from deployCore()
 *    mm, mmAddr,        // P2P counterparty (funded with ppUSDC)
 *    oracle,            // MockOracle instance
 *    markets,           // [{ marketId, posYes, posNo }, ...]
 *  }
 */
async function setupResolvingMarketsGasFixture({
  nMarkets = 20,
  buySizeUSDC = "10",
} = {}) {
  const fx = await deployCore();
  const { ledger, trader, owner, usdc: usdcToken } = fx;

  // P2P counterparty address
  const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
  const mm = await Flat.deploy();
  await mm.waitForDeployment();
  const mmAddr = await mm.getAddress();

  // Oracle
  const MockOracle = await ethers.getContractFactory("MockOracle");
  const oracle = await MockOracle.deploy();
  await oracle.waitForDeployment();
  const oracleAddr = await oracle.getAddress();

  // Fund + deposit trader and mm with plenty of ppUSDC
  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader,
    amount: U(200_000),
  });

  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader: owner,
    to: mmAddr,
    amount: U(200_000),
  });

  const markets = [];
  const BUY = U(buySizeUSDC);

  for (let i = 0; i < nMarkets; i++) {
    // 1) Create resolving market (no DMM, no ISC)
    await ledger
      .connect(owner)
      .createMarket(
        `Gas Res ${i}`,
        `GR${i}`,
        ethers.ZeroAddress, // no DMM
        0n,                 // no ISC
        true,               // doesResolve
        oracleAddr,         // oracle
        "0x",               // oracleParams
        0,                  // feeBps
        owner.address,      // marketCreator
        [],                 // feeWhitelistAccounts
        false               // hasWhitelist
      );

    const allMarkets = await ledger.getMarkets();
    const marketId = allMarkets[allMarkets.length - 1];

    // 2) Two positions: YES / NO
    await ledger.connect(owner).createPosition(marketId, "YES", "Y");
    await ledger.connect(owner).createPosition(marketId, "NO",  "N");

    const posIds = await ledger.getMarketPositions(marketId);
    const posYes = posIds[0];
    const posNo  = posIds[1];

    // 3) Trader buys YES vs mm (BACK)
    await ledger.connect(trader).buyExactTokens(
      mmAddr,
      marketId,
      posYes,
      true,          // isBack
      BUY,
      U(1_000_000)   // very high bound
    );

    markets.push({ marketId, posYes, posNo });
  }

  return {
    fx,
    mm,
    mmAddr,
    oracle,
    markets,
  };
}

/**
 * Resolve all markets via MockOracle, with a configurable set of winners.
 *
 * @param {object} ctx
 *  - fx, oracle, markets
 * @param {object} opts
 *  - winnersPredicate: (idx, {marketId,posYes,posNo}) => winningPositionId
 *      default: every market's YES wins
 */
async function resolveMarketsViaOracle(ctx, opts = {}) {
  const { fx, oracle, markets } = ctx;
  const { winnersPredicate } = opts;

  for (let i = 0; i < markets.length; i++) {
    const m = markets[i];

    const winningPositionId = winnersPredicate
      ? winnersPredicate(i, m)
      : m.posYes; // default: trader wins all

    await oracle.pushResolution(m.marketId, winningPositionId);
    await fx.ledger.resolveMarket(m.marketId);
  }
}

module.exports = {
  setupResolvingMarketsGasFixture,
  resolveMarketsViaOracle,
};
