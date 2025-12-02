// test/helpers/lmsr.ledger.js
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { usdc, deployCore, mintAndDeposit } = require("./core");

async function setupLmsrLedgerFixture() {
  // Core ledger + tokens, same pattern as other tests
  const fx = await deployCore();
  const { owner, trader, ledger } = fx;

  // 1) Deploy LMSRMarketMaker wired to the real ledger
  const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
  fx.lmsr = await LMSR.deploy(
    owner.address,              // governor
    await ledger.getAddress()   // ILedgerPositions
  );
  await fx.lmsr.waitForDeployment();

  const lmsrAddr = await fx.lmsr.getAddress();

  // 2) Allow LMSR as a DMM (no freeCollateral deposit – it will use ISC)
  await ledger.connect(owner).allowDMM(lmsrAddr, true);

  // 3) Create market on the ledger with an ISC line, like setupMarketFixture
  const iscAmount = usdc("100000"); // 100k synthetic, same as your flatMM tests

  await ledger.createMarket(
    "LMSR Test Market",
    "LMSR",
    lmsrAddr,
    iscAmount,
    false,              // doesResolve = false
    ethers.ZeroAddress, // oracle
    "0x"  );

  const markets = await ledger.getMarkets();
  expect(markets.length).to.equal(1);
  fx.marketId = markets[0];

  // 4) Create YES / NO positions on the ledger
  await ledger.createPosition(fx.marketId, "YES", "YES");
  await ledger.createPosition(fx.marketId, "NO",  "NO");

  const positionIds = await ledger.getMarketPositions(fx.marketId);
  expect(positionIds.length).to.equal(2);

  fx.yesId = positionIds[0];
  fx.noId  = positionIds[1];

  // 5) Initialise the LMSR AMM side for that market with 50/50 priors
  const priors = [
    { positionId: fx.yesId, r: ethers.parseEther("0.5") },
    { positionId: fx.noId,  r: ethers.parseEther("0.5") },
  ];

  // This is the AMM’s internal liability parameter; independent of ISC line
  const liabilityUSDC = usdc("1000"); // e.g. 1,000 USDC max liability

  await fx.lmsr
    .connect(owner)
    .initMarket(
      fx.marketId,
      priors,
      liabilityUSDC,
      0,      // reserve0
      false   // isExpanding
    );

  return fx;
}

// Trader deposits to ledger then trades against LMSR via DMM route
async function traderDepositsAndBuysLmsr(
  fx,
  { depositAmount, tokensToBuy, maxUsdcIn }
) {
  const {
    usdc: usdcToken,
    trader,
    ledger,
    lmsr,
    marketId,
    yesId,
  } = fx;

  // 1) Fund trader + deposit into ledger (ppUSDC mirror as usual)
  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader,
    amount: depositAmount,
  });

  // 2) Execute buy against LMSR DMM via the ledger
  await ledger.connect(trader).buyExactTokens(
    await lmsr.getAddress(), // DMM = LMSR
    marketId,
    yesId,
    true,                    // isBack
    tokensToBuy,
    maxUsdcIn
  );
}

module.exports = {
  setupLmsrLedgerFixture,
  traderDepositsAndBuysLmsr,
};
