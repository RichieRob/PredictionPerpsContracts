// test/helpers/normalizedLinear.ledger.js
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { usdc, deployCore, mintAndDeposit } = require("./core");

function toPlainBigintArray(resultArray) {
  return Array.from(resultArray, (x) => BigInt(x));
}

/**
 * Sets up a ledger + NormalizedLinearInventoryMarketMaker market
 */
async function setupNormalizedLinearLedgerFixture({
  outcomes = ["A", "B", "C"],
  priors = null,              // array of WAD priors, defaults to equal
  kWad = ethers.parseEther("1"),
} = {}) {
  const fx = await deployCore();
  const { owner, ledger } = fx;

  // 1) Deploy NormalizedLinearInventoryMarketMaker wired to the ledger
  const NL = await ethers.getContractFactory(
    "NormalizedLinearInventoryMarketMaker"
  );
  fx.nl = await NL.deploy(owner.address, await ledger.getAddress());
  await fx.nl.waitForDeployment();

  const nlAddr = await fx.nl.getAddress();

  // 2) Allow NL as a DMM
  await ledger.connect(owner).allowDMM(nlAddr, true);

  // 3) Create market with ISC line
  const iscAmount = usdc("100000");
  await ledger.connect(owner).createMarket(
    "Normalized Linear Test Market",
    "NLI",
    nlAddr,
    iscAmount,
    false,
    ethers.ZeroAddress,
    "0x",
    0,
    owner.address,
    [],
    false
  );

  const marketsRes = await ledger.getMarkets();
  const markets = toPlainBigintArray(marketsRes);
  expect(markets.length).to.equal(1);
  fx.marketId = markets[0];

  // 4) Create positions
  for (const name of outcomes) {
    await ledger.connect(owner).createPosition(fx.marketId, name, name);
  }

  const posRes = await ledger.getMarketPositions(fx.marketId);
  fx.positionIds = toPlainBigintArray(posRes);
  expect(fx.positionIds.length).to.equal(outcomes.length);

  fx.pos0 = fx.positionIds[0];
  fx.pos1 = fx.positionIds[1];
  fx.pos2 = fx.positionIds[2] ?? 0n;

  // 5) Init NormalizedLinear market
  // Build InitialPosition[] = { positionId, priorWad }
  const defaultPrior = ethers.parseEther("1");
  const initialPositions = fx.positionIds.map((pid, i) => ({
    positionId: pid,
    priorWad: priors ? priors[i] : defaultPrior,
  }));

  await fx.nl.connect(owner).initMarket(
    fx.marketId,
    initialPositions,
    kWad
  );

  return fx;
}

/**
 * Trader deposits USDC and buys via NormalizedLinear MM
 */
async function traderDepositsAndBuysNormalizedLinear(
  fx,
  { depositAmount, positionId, isBack, tokensToBuy, maxUsdcIn }
) {
  const { usdc: usdcToken, trader, ledger, nl, marketId } = fx;

  if (depositAmount && depositAmount > 0n) {
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: depositAmount,
    });
  }

  // Ledger reverts on t = 0 → skip no-op buys
  if (tokensToBuy && tokensToBuy > 0n) {
    await ledger.connect(trader).buyExactTokens(
      await nl.getAddress(),
      marketId,
      positionId,
      isBack,
      tokensToBuy,
      maxUsdcIn
    );
  }
}

module.exports = {
  setupNormalizedLinearLedgerFixture,
  traderDepositsAndBuysNormalizedLinear,
};
