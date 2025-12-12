// test/helpers/vf.ledger.js
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { usdc, deployCore, mintAndDeposit } = require("./core");

function toPlainBigintArray(resultArray) {
  return Array.from(resultArray, (x) => BigInt(x));
}

async function setupVfLedgerFixture({
  outcomes = ["A", "B", "C"],
  V = usdc("10000"),
} = {}) {
  const fx = await deployCore();
  const { owner, ledger } = fx;

  // 1) Deploy VFMarketMaker wired to the real ledger
  const VF = await ethers.getContractFactory("VFMarketMaker");
  fx.vf = await VF.deploy(owner.address, await ledger.getAddress());
  await fx.vf.waitForDeployment();

  const vfAddr = await fx.vf.getAddress();

  // 2) Allow VF as a DMM
  await ledger.connect(owner).allowDMM(vfAddr, true);

  // 3) Create market with ISC line
  const iscAmount = usdc("100000");
  await ledger.connect(owner).createMarket(
    "VF Test Market",
    "VF",
    vfAddr,
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

  // 5) Init VF market (IMPORTANT: pass plain array)
  await fx.vf.connect(owner).initMarket(fx.marketId, fx.positionIds, V);

  return fx;
}

async function traderDepositsAndBuysVf(
  fx,
  { depositAmount, positionId, isBack, tokensToBuy, maxUsdcIn }
) {
  const { usdc: usdcToken, trader, ledger, vf, marketId } = fx;

  if (depositAmount && depositAmount > 0n) {
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: depositAmount,
    });
  }

  // ✅ Ledger likely reverts on t=0, so skip “no-op buys”
  if (tokensToBuy && tokensToBuy > 0n) {
    await ledger.connect(trader).buyExactTokens(
      await vf.getAddress(),
      marketId,
      positionId,
      isBack,
      tokensToBuy,
      maxUsdcIn
    );
  }
}

module.exports = {
  setupVfLedgerFixture,
  traderDepositsAndBuysVf,
};
