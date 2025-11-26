// test/helpers/resolution.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  usdc,
  deployCore,
  mintAndDeposit,
  EMPTY_PERMIT,
} = require("./core");

// Deploy mock oracle
async function deployMockOracle() {
  const MockOracle = await ethers.getContractFactory("MockOracle");
  const oracle = await MockOracle.deploy();
  await oracle.waitForDeployment();
  return oracle;
}

// Setup a clean resolvable market: no DMM, no ISC, flat pricing via mock MM
async function setupResolvableMarketFixture() {
  const fx = await deployCore();
  const { ledger, owner, trader, usdc: usdcToken } = fx;

  // Deploy flat mock market maker (not a DMM)
  const FlatMM = await ethers.getContractFactory("FlatMockMarketMaker");
  fx.flatMM = await FlatMM.deploy();
  await fx.flatMM.waitForDeployment();

  const mmAddr = await fx.flatMM.getAddress();

  // Fund MM with USDC deposit
  const mmFunding = usdc("1000000");
  await usdcToken.mint(owner.address, mmFunding);
  await usdcToken.connect(owner).approve(await ledger.getAddress(), mmFunding);
  await ledger.connect(owner).deposit(
    mmAddr,
    mmFunding,
    0n,
    0,
    EMPTY_PERMIT,
    "0x"
  );

  // Deploy oracle
  fx.oracle = await deployMockOracle();

  // Create resolvable market: dmm = address(0), isc = 0
  await ledger.createMarket(
    "Will Trump win 2024?",
    "TRUMP24",
    ethers.ZeroAddress,
    0n,
    true,
    await fx.oracle.getAddress(),
    "0x"
  );

  const markets = await ledger.getMarkets();
  fx.marketId = markets[markets.length - 1];

  // Create YES / NO positions
  const [yesId] = await ledger.createPosition.staticCall(fx.marketId, "YES", "YES");
  await ledger.createPosition(fx.marketId, "YES", "YES");

  const [noId] = await ledger.createPosition.staticCall(fx.marketId, "NO", "NO");
  await ledger.createPosition(fx.marketId, "NO", "NO");

  fx.yesId = yesId;
  fx.noId = noId;

  return fx;
}

// Trader buys YES shares from the mock MM
async function traderBuysYes(fx, { depositAmount, tokensToBuy, maxUSDCIn = ethers.MaxUint256 }) {
  await mintAndDeposit({
    usdc: fx.usdc,
    ledger: fx.ledger,
    trader: fx.trader,
    amount: depositAmount,
  });

  await fx.ledger.connect(fx.trader).buyExactTokens(
    await fx.flatMM.getAddress(),
    fx.marketId,
    fx.yesId,
    true,
    tokensToBuy,
    maxUSDCIn
  );
}

async function expectResolutionAndClaiming(fx, { expectedWinnings }) {
  const { ledger, trader, marketId, owner } = fx;

  await ledger.connect(owner).resolveMarket(marketId);

  const realBefore = await ledger.realFreeCollateral(trader.address);
  const effectiveBefore = await ledger.effectiveFreeCollateral(trader.address);

  await ledger.connect(trader).claimAllPendingWinnings();

  const realAfter = await ledger.realFreeCollateral(trader.address);
  const effectiveAfter = await ledger.effectiveFreeCollateral(trader.address);

  expect(realAfter).to.equal(realBefore + expectedWinnings);
  expect(effectiveAfter).to.equal(effectiveBefore);
}

module.exports = {
  deployMockOracle,
  setupResolvableMarketFixture,
  traderBuysYes,
  expectResolutionAndClaiming,
  // add expectClaimOnUnresolvedReverts if needed
};