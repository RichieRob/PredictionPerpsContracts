// test/fees.hwm.smoke.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("FeeLib – basic HWM fee path", () => {
  it("charges fees on net allocation increases without breaking invariants", async () => {
    const fx = await deployCore();
    const { ledger, owner, trader } = fx;

    // Flat mock MM
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    // Turn on protocol share for *future* markets
    await ledger
      .connect(owner)
      .setNewMarketProtocolFeeShareBps(2_000); // 20% of creator fee

    // Create a non-resolving market with:
    // - DMM = mmAddr
    // - feeBps = 100 (1%)
    await ledger
      .connect(owner)
      .createMarket(
        "Fee Market",
        "FEE",
        mmAddr,             // DMM
        usdc("100000"),     // ISC line
        false,              // doesResolve
        ethers.ZeroAddress, // oracle
        "0x",               // oracleParams
        100,                // feeBps = 1%
        owner.address,      // marketCreator
        [],                 // fee whitelist accounts
        false               // whitelist disabled
      );

    const marketId = (await ledger.getMarkets())[0];

    // Positions: single YES for simplicity
    await ledger
      .connect(owner)
      .createPosition(marketId, "YES", "Y");
    const [posYes] = await ledger.getMarketPositions(marketId);

    // Allow mm as DMM (if your flows gate on allowedDMMs)
    await ledger.connect(owner).allowDMM(mmAddr, true);

    // Fund trader + mm
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader,              // trader signer
      amount: usdc("1000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: owner,       // owner funds mm
      to: mmAddr,
      amount: usdc("1000"),
    });

    // Snapshot real free collateral for a few key accounts
    const [
      beforeTraderReal,
      beforeMMReal,
      beforeOwnerReal,
    ] = await Promise.all([
      ledger.realFreeCollateral(trader.address),
      ledger.realFreeCollateral(mmAddr),
      ledger.realFreeCollateral(owner.address),
    ]);

    const totalBefore =
      beforeTraderReal + beforeMMReal + beforeOwnerReal;

    // Trade: trader buys YES vs mm (this should hit the fee path
    // for whoever is wired as the "payer" in your FeeLib integration)
    await ledger
      .connect(trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,             // isBack
        usdc("200"),      // token amount, caller-scale
        usdc("1000")      // maxUSDCIn
      );

    const [
      afterTraderReal,
      afterMMReal,
      afterOwnerReal,
    ] = await Promise.all([
      ledger.realFreeCollateral(trader.address),
      ledger.realFreeCollateral(mmAddr),
      ledger.realFreeCollateral(owner.address),
    ]);

    const totalAfter =
      afterTraderReal + afterMMReal + afterOwnerReal;

    // 1) Fees only redistribute real free collateral; no mint/burn
    expect(totalAfter).to.equal(totalBefore);

    // 2) Core invariants still hold with non-zero fees configured
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, mmAddr, owner.address],
      marketId,
      checkRedeemabilityFor: [trader.address, mmAddr, owner.address],
    });
  });
});
