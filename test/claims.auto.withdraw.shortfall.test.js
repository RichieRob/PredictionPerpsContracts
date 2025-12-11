// test/claims.auto.withdraw.shortfall.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");
const { resolveViaMockOracle } = require("./helpers/resolution");

describe("ClaimsLib – auto-claim on withdraw shortfall", () => {
  it("auto-claims enough winnings to cover a withdraw that exceeds real but not effective", async () => {
    const fx = await deployCore();
    const { trader } = fx;

    // Set up resolving market with one winning position
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    await oracle.waitForDeployment();

    await fx.ledger.createMarket(
      "Auto-claim test",
      "ACT",
      ethers.ZeroAddress,
      0,
      true,
      await oracle.getAddress(),
      "0x",
      0,                 // feeBps
      fx.owner.address,  // marketCreator
      [],
      false              // hasWhitelist
    );
    const marketId = (await fx.ledger.getMarkets())[0];

    await fx.ledger.createPosition(marketId, "YES", "Y");
    const posIds = await fx.ledger.getMarketPositions(marketId);
    const posYes = posIds[0];

    // Fund trader + mm
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader,
      amount: usdc("1000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.owner,
      to: mmAddr,
      amount: usdc("1000"),
    });

    // Trader buys YES
    await fx.ledger
      .connect(trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,
        usdc("200"),
        usdc("1000")
      );

    // Resolve YES
    await resolveViaMockOracle({
      oracle,
      ledger: fx.ledger,
      marketId,
      winningPositionId: posYes,
    });

    const preReal = await fx.ledger.realFreeCollateral(trader.address);
    const preEff  = await fx.ledger.effectiveFreeCollateral(trader.address);
    const pending = preEff - preReal;
    expect(pending).to.be.gt(0n);

    // Ask to withdraw more than real, but less than real + pending
    const withdrawAmount = preReal + pending / 2n;

    await fx.ledger
      .connect(trader)
      .withdraw(withdrawAmount, trader.address);

    const postReal = await fx.ledger.realFreeCollateral(trader.address);
    const postEff  = await fx.ledger.effectiveFreeCollateral(trader.address);

    // 1) Withdraw succeeded without underflow
    expect(postReal).to.be.gte(0n);

    // 2) effective free collateral dropped by exactly withdrawAmount
    expect(preEff - postEff).to.equal(withdrawAmount);

    // 3) Auto-claim has realised SOME (possibly all) pending winnings
    const postPending = postEff - postReal;
    expect(postPending).to.be.gte(0n);
    expect(postPending).to.be.lte(pending);

    const shortfall = withdrawAmount - preReal;
    const claimedFromPending = pending - postPending;

    // We must have realised at least enough to cover the shortfall,
    // but never more than the total pending.
    expect(claimedFromPending).to.be.gte(shortfall);
    expect(claimedFromPending).to.be.lte(pending);

    // 4) Subsequent batchClaimWinnings should be a no-op in this 1-market setup
    //    (all pending was already realised by auto-claim).
    const preClaimPp = await fx.ppUSDC.balanceOf(trader.address);

    await fx.ledger
      .connect(trader)
      .batchClaimWinnings(trader.address, [marketId]);

    const postClaimPp = await fx.ppUSDC.balanceOf(trader.address);

    // No extra visible bump: nothing left to claim.
    expect(postClaimPp).to.equal(preClaimPp);
  });
});
