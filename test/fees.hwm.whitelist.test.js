// test/fees.hwm.whitelist.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");

describe("FeeLib – whitelist behaviour", () => {
  it("does not charge HWM fees to a whitelisted MM", async () => {
    const fx = await deployCore();
    const { ledger } = fx;
    const [owner, trader, mmFunder, marketCreator] = await ethers.getSigners();

    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    // Enable protocol share (for realism; not essential to the whitelist behaviour)
    await ledger.connect(owner).setNewMarketProtocolFeeShareBps(2_000); // 20%

    // Create a market with a fee, whitelist enabled, and **no ISC**
    // so the MM is NOT auto-whitelisted by virtue of being the DMM.
    await ledger.connect(owner).createMarket(
      "FeeMarketWL",
      "FMW",
      mmAddr,
      usdc("0"),             // NO ISC: DMM not auto-whitelisted
      false,
      ethers.ZeroAddress,
      "0x",
      5_000,                 // 50% fee
      marketCreator.address,
      [],
      true                   // hasWhitelist = true
    );

    const marketId = (await ledger.getMarkets())[0];

    await ledger.connect(marketCreator).createPosition(marketId, "YES", "Y");
    const [posYes] = await ledger.getMarketPositions(marketId);

    await ledger.connect(owner).allowDMM(mmAddr, true);

    // Explicitly whitelist MM for this market
    await ledger
      .connect(marketCreator)
      .setFeeWhitelist(marketId, mmAddr, true);

    // Fund trader + MM
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader,
      amount: usdc("1000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: mmFunder,
      to: mmAddr,
      amount: usdc("1000"),
    });

    const beforeCreatorFree = await ledger.realFreeCollateral(
      marketCreator.address
    );
    const beforeOwnerFree = await ledger.realFreeCollateral(owner.address);

    const beforeMM = await ledger.debugFeeState(mmAddr, marketId);

    // Trade (this would normally generate HWM fees if not whitelisted)
    await ledger
      .connect(trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,
        usdc("200"),
        usdc("1000")
      );

    const afterCreatorFree = await ledger.realFreeCollateral(
      marketCreator.address
    );
    const afterOwnerFree = await ledger.realFreeCollateral(owner.address);

    const afterMM = await ledger.debugFeeState(mmAddr, marketId);

    // ❗ Current implementation: whitelisted MMs do NOT advance HWM at all.
    // So HWM should remain unchanged.
    expect(afterMM.hwm).to.equal(beforeMM.hwm);

    // And absolutely no fees should be credited to creator / protocol.
    expect(afterCreatorFree).to.equal(beforeCreatorFree);
    expect(afterOwnerFree).to.equal(beforeOwnerFree);
  });
});
