// test/ledger.position.peertopeer.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore } = require("./helpers/core");

describe("MarketMakerLedger – peer-to-peer PositionERC20 transfers", function () {
  let owner, dmm, trader1, trader2;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;
  let marketId, positionId, positionToken;

  beforeEach(async function () {
    // Reuse shared core deployment:
    // fx: { owner, trader, feeRecipient, other, usdc, aUSDC, aavePool, ppUSDC, ledger }
    const fx = await deployCore();

    ({ owner, usdc, aUSDC, aavePool, ppUSDC, ledger } = fx);

    // Re-map roles for this test
    dmm      = fx.trader;       // acts as DMM / initial holder of created-shares
    trader1  = fx.feeRecipient; // first P2P trader
    trader2  = fx.other;        // second P2P trader

    // Allow DMM
    await ledger.allowDMM(dmm.address, true);

    // --- create market ---
    const iscSeed = ethers.parseUnits("1000", 6);
    await ledger.createMarket(
      "Test Market",
      "TM",
      dmm.address,
      iscSeed,
      false,              // doesResolve
      ethers.ZeroAddress, // oracle
      "0x",
      false              // oracleParams
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // --- create 1 YES position & get PositionERC20 address via staticCall ---
    const [predPosId, tokenAddr] = await ledger.createPosition.staticCall(
      marketId,
      "YES",
      "YES"
    );
    await ledger.createPosition(marketId, "YES", "YES");

    positionId   = predPosId;
    positionToken = await ethers.getContractAt("PositionERC20", tokenAddr);

    // DMM owns all created-shares initially – give some to trader1
    const dmmBal       = await positionToken.balanceOf(dmm.address);
    const seedToTrader = dmmBal / 4n;

    await positionToken.connect(dmm).transfer(trader1.address, seedToTrader);
  });

  it("PositionERC20 transfer moves created-shares between traders and preserves totalSupply", async function () {
    const supplyBefore = await positionToken.totalSupply();
    const bal1Before   = await positionToken.balanceOf(trader1.address);
    const bal2Before   = await positionToken.balanceOf(trader2.address);

    expect(bal1Before).to.be.gt(0n);

    const transferAmount = bal1Before / 2n;

    await positionToken
      .connect(trader1)
      .transfer(trader2.address, transferAmount);

    const supplyAfter = await positionToken.totalSupply();
    const bal1After   = await positionToken.balanceOf(trader1.address);
    const bal2After   = await positionToken.balanceOf(trader2.address);

    // totals unchanged, just balances moved
    expect(supplyAfter).to.equal(supplyBefore);
    expect(bal1After).to.equal(bal1Before - transferAmount);
    expect(bal2After).to.equal(bal2Before + transferAmount);
  });

  it("reverts PositionERC20 transfer when sender doesn't have enough shares", async function () {
    const bal1    = await positionToken.balanceOf(trader1.address);
    const tooMuch = bal1 + 1n;

    await expect(
      positionToken.connect(trader1).transfer(trader2.address, tooMuch)
    ).to.be.reverted; // tighten to specific message if you want
  });

  it("PositionERC20 P2P transfer preserves solvency & ISC line", async function () {
    // Grab system-level invariants before the transfer
    const [usedBefore, lineBefore] = await ledger.invariant_iscWithinLine(
      marketId
    );
    const effMinBefore = await ledger.invariant_effectiveMin(
      dmm.address,
      marketId
    );
    const fundingBefore = await ledger.invariant_systemFunding(marketId);

    const amount = await positionToken.balanceOf(trader1.address);
    await positionToken.connect(trader1).transfer(trader2.address, amount);

    const [usedAfter, lineAfter] = await ledger.invariant_iscWithinLine(
      marketId
    );
    const effMinAfter = await ledger.invariant_effectiveMin(
      dmm.address,
      marketId
    );
    const fundingAfter = await ledger.invariant_systemFunding(marketId);

    // P2P should not change global accounting / ISC
    expect(usedAfter).to.equal(usedBefore);
    expect(lineAfter).to.equal(lineBefore);
    expect(effMinAfter).to.equal(effMinBefore);
    expect(fundingAfter).to.equal(fundingBefore);
  });
});
