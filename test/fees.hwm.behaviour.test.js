// test/fees.hwm.behaviour.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("FeeLib – HWM behaviour & distribution", () => {
  // ---------------------------------------------------------------------------
  // 1) Fees go to creator + protocol and are withdrawable
  // ---------------------------------------------------------------------------
  it("accrues fees to creator + protocol and they can withdraw them", async () => {
    const fx = await deployCore();
    const { ledger } = fx;

    const signers = await ethers.getSigners();
    const ledgerOwner   = signers[0]; // protocol owner (same as fx.owner)
    const traderSigner  = signers[1];
    const mmFunder      = signers[2];
    const marketCreator = signers[3];

    // Flat mock MM
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    // Turn on protocol share for *future* markets (20% of creator fee)
    await ledger
      .connect(ledgerOwner)
      .setNewMarketProtocolFeeShareBps(2_000); // 20% protocol share

    // Create a non-resolving market with:
    // - DMM = mmAddr
    // - ISC = 0 (IMPORTANT: no auto-whitelist; MM should pay HWM fees)
    // - feeBps = 100% (10_000 bps) so feeBase = Δ(netAlloc) for clarity
    await ledger
      .connect(ledgerOwner)
      .createMarket(
        "Fee Market Withdraw",
        "FMW",
        mmAddr,             // DMM
        usdc("0"),          // ISC = 0 → MM is NOT auto-whitelisted
        false,              // doesResolve
        ethers.ZeroAddress, // oracle
        "0x",               // oracleParams
        10_000,             // feeBps = 100%
        marketCreator.address,
        [],                 // fee whitelist
        false               // whitelist disabled
      );

    const marketId = (await ledger.getMarkets())[0];

    // Creator must add positions
    await ledger
      .connect(marketCreator)
      .createPosition(marketId, "YES", "Y");
    const [posYes] = await ledger.getMarketPositions(marketId);

    // Allow MM as DMM (no ISC, so just normal MM that can use the market)
    await ledger.connect(ledgerOwner).allowDMM(mmAddr, true);

    // Fund trader & mm (owner never deposits → any gain for owner is pure fees)
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: traderSigner,
      amount: usdc("1000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: mmFunder,
      to: mmAddr,
      amount: usdc("1000"),
    });

    const beforeCreatorReal = await ledger.realFreeCollateral(marketCreator.address);
    const beforeOwnerReal   = await ledger.realFreeCollateral(ledgerOwner.address);

    // Trade that should hit the fee path
    await ledger
      .connect(traderSigner)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,             // isBack
        usdc("200"),
        usdc("1000")
      );

    const afterCreatorReal = await ledger.realFreeCollateral(marketCreator.address);
    const afterOwnerReal   = await ledger.realFreeCollateral(ledgerOwner.address);

    const deltaCreator = afterCreatorReal - beforeCreatorReal;
    const deltaOwner   = afterOwnerReal   - beforeOwnerReal;

    // 1) Both creator and protocol should have gained some realFreeCollateral
    expect(deltaCreator).to.be.gt(0n);
    expect(deltaOwner).to.be.gt(0n);

    // 2) They can withdraw those fees
    const creatorWithdraw = deltaCreator / 2n > 0n ? deltaCreator / 2n : deltaCreator;
    const ownerWithdraw   = deltaOwner   / 2n > 0n ? deltaOwner   / 2n : deltaOwner;

    await ledger
      .connect(marketCreator)
      .withdraw(creatorWithdraw, marketCreator.address);

    await ledger
      .connect(ledgerOwner)
      .withdraw(ownerWithdraw, ledgerOwner.address);

    const finalCreatorReal = await ledger.realFreeCollateral(marketCreator.address);
    const finalOwnerReal   = await ledger.realFreeCollateral(ledgerOwner.address);

    expect(finalCreatorReal).to.equal(afterCreatorReal - creatorWithdraw);
    expect(finalOwnerReal).to.equal(afterOwnerReal - ownerWithdraw);

    // 3) Invariants still hold
    await expectCoreSystemInvariants(fx, {
      accounts: [
        traderSigner.address,
        mmAddr,
        marketCreator.address,
        ledgerOwner.address,
      ],
      marketId,
      checkRedeemabilityFor: [
        traderSigner.address,
        mmAddr,
        marketCreator.address,
        ledgerOwner.address,
      ],
    });
  });

  // ---------------------------------------------------------------------------
  // 2) feeBps only applies on that market (per-market isolation)
  // ---------------------------------------------------------------------------
  it("only charges fees on markets with non-zero feeBps", async () => {
    const fx = await deployCore();
    const { ledger } = fx;

    const signers = await ethers.getSigners();
    const ledgerOwner   = signers[0];
    const traderSigner  = signers[1];
    const mmFunder      = signers[2];
    const marketCreator = signers[3];

    // MM
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    // Two markets:
    //  - marketNoFee: feeBps = 0
    //  - marketFee:   feeBps = 100% (10_000) so we definitely see non-zero fee
    // IMPORTANT: ISC = 0 in both so MM is not auto-whitelisted and can be charged.

    // Market with NO fee
    await ledger
      .connect(ledgerOwner)
      .createMarket(
        "No Fee Market",
        "NF",
        mmAddr,
        usdc("0"),          // ISC = 0 → no auto-whitelist
        false,
        ethers.ZeroAddress,
        "0x",
        0,                  // feeBps = 0
        marketCreator.address,
        [],
        false
      );
    const marketNoFee = (await ledger.getMarkets())[0];

    // Market WITH fee
    await ledger
      .connect(ledgerOwner)
      .createMarket(
        "Fee Market",
        "FEE",
        mmAddr,
        usdc("0"),          // ISC = 0 → no auto-whitelist
        false,
        ethers.ZeroAddress,
        "0x",
        10_000,             // feeBps = 100%
        marketCreator.address,
        [],
        false
      );
    const marketFee = (await ledger.getMarkets())[1];

    // Positions for both markets (creator must call)
    await ledger
      .connect(marketCreator)
      .createPosition(marketNoFee, "YES", "Y");
    await ledger
      .connect(marketCreator)
      .createPosition(marketFee, "YES", "Y");

    const [posNF] = await ledger.getMarketPositions(marketNoFee);
    const [posF]  = await ledger.getMarketPositions(marketFee);

    await ledger.connect(ledgerOwner).allowDMM(mmAddr, true);

    // Fund trader & mm (owner not used in flows)
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: traderSigner,
      amount: usdc("2000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: mmFunder,
      to: mmAddr,
      amount: usdc("2000"),
    });

    const beforeCreatorReal = await ledger.realFreeCollateral(marketCreator.address);
    const beforeOwnerReal   = await ledger.realFreeCollateral(ledgerOwner.address);

    // --- Trade ONLY in no-fee market ---
    await ledger
      .connect(traderSigner)
      .buyExactTokens(
        mmAddr,
        marketNoFee,
        posNF,
        true,
        usdc("200"),
        usdc("1000")
      );

    const afterNoFeeCreator = await ledger.realFreeCollateral(marketCreator.address);
    const afterNoFeeOwner   = await ledger.realFreeCollateral(ledgerOwner.address);

    // No fees should have been credited for feeBps = 0 market
    expect(afterNoFeeCreator).to.equal(beforeCreatorReal);
    expect(afterNoFeeOwner).to.equal(beforeOwnerReal);

    // --- Trade in fee-charging market ---
    await ledger
      .connect(traderSigner)
      .buyExactTokens(
        mmAddr,
        marketFee,
        posF,
        true,
        usdc("200"),
        usdc("1000")
      );

    const afterFeeCreator = await ledger.realFreeCollateral(marketCreator.address);
    const afterFeeOwner   = await ledger.realFreeCollateral(ledgerOwner.address);

    // Now the creator should see an increase
    expect(afterFeeCreator).to.be.gt(afterNoFeeCreator);
    // owner might have 0 protocol share configured; we just assert >= (no decrease)
    expect(afterFeeOwner).to.be.gte(afterNoFeeOwner);

    // Invariants still ok
    await expectCoreSystemInvariants(fx, {
      accounts: [
        traderSigner.address,
        mmAddr,
        marketCreator.address,
        ledgerOwner.address,
      ],
      marketId: marketFee,
      checkRedeemabilityFor: [
        traderSigner.address,
        mmAddr,
        marketCreator.address,
        ledgerOwner.address,
      ],
    });
  });

  // ---------------------------------------------------------------------------
  // 3) Global protocol share applies only to *future* markets
  // ---------------------------------------------------------------------------
  it("applies global protocol fee share only to markets created *after* it is set", async () => {
    const fx = await deployCore();
    const { ledger } = fx;

    const signers = await ethers.getSigners();
    const ledgerOwner   = signers[0];
    const traderSigner  = signers[1];
    const mmFunder      = signers[2];
    const oldCreator    = signers[3];
    const newCreator    = signers[4];

    // MM
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const mm = await Flat.deploy();
    await mm.waitForDeployment();
    const mmAddr = await mm.getAddress();

    // ---------------- Old market (created BEFORE protocol share set) ----------------
    await ledger
      .connect(ledgerOwner)
      .createMarket(
        "Old Fee Market",
        "OLD",
        mmAddr,
        usdc("0"),          // ISC = 0 → no auto-whitelist
        false,
        ethers.ZeroAddress,
        "0x",
        10_000,             // 100% fee so we see clear deltas
        oldCreator.address,
        [],
        false
      );
    const marketOld = (await ledger.getMarkets())[0];

    await ledger
      .connect(oldCreator)
      .createPosition(marketOld, "YES", "Y");
    const [posOld] = await ledger.getMarketPositions(marketOld);

    // ---------------- Set protocol share for FUTURE markets ----------------
    await ledger
      .connect(ledgerOwner)
      .setNewMarketProtocolFeeShareBps(2_000); // 20% protocol share

    // ---------------- New market (created AFTER protocol share set) ----------------
    await ledger
      .connect(ledgerOwner)
      .createMarket(
        "New Fee Market",
        "NEW",
        mmAddr,
        usdc("0"),          // ISC = 0 → no auto-whitelist
        false,
        ethers.ZeroAddress,
        "0x",
        10_000,             // 100% fee
        newCreator.address,
        [],
        false
      );
    const marketNew = (await ledger.getMarkets())[1];

    await ledger
      .connect(newCreator)
      .createPosition(marketNew, "YES", "Y");
    const [posNew] = await ledger.getMarketPositions(marketNew);

    await ledger.connect(ledgerOwner).allowDMM(mmAddr, true);

    // Fund trader & mm – owner never deposits (so any gain for owner is pure protocol fees)
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: traderSigner,
      amount: usdc("4000"),
    });

    await mintAndDeposit({
      usdc: fx.usdc,
      ledger,
      trader: mmFunder,
      to: mmAddr,
      amount: usdc("4000"),
    });

    const beforeOwnerReal  = await ledger.realFreeCollateral(ledgerOwner.address);
    const beforeOldCreator = await ledger.realFreeCollateral(oldCreator.address);
    const beforeNewCreator = await ledger.realFreeCollateral(newCreator.address);

    // --- Trade in OLD market (created before protocol share was set) ---
    await ledger
      .connect(traderSigner)
      .buyExactTokens(
        mmAddr,
        marketOld,
        posOld,
        true,
        usdc("300"),
        usdc("1500")
      );

    const afterOld_owner  = await ledger.realFreeCollateral(ledgerOwner.address);
    const afterOld_oldCr  = await ledger.realFreeCollateral(oldCreator.address);
    const afterOld_newCr  = await ledger.realFreeCollateral(newCreator.address);

    // Owner should NOT receive protocol fees from the old market
    expect(afterOld_owner).to.equal(beforeOwnerReal);
    // Old creator should receive something
    expect(afterOld_oldCr).to.be.gt(beforeOldCreator);
    // New creator unchanged
    expect(afterOld_newCr).to.equal(beforeNewCreator);

    // --- Trade in NEW market (created after protocol share was set) ---
    await ledger
      .connect(traderSigner)
      .buyExactTokens(
        mmAddr,
        marketNew,
        posNew,
        true,
        usdc("300"),
        usdc("1500")
      );

    const afterNew_owner  = await ledger.realFreeCollateral(ledgerOwner.address);
    const afterNew_oldCr  = await ledger.realFreeCollateral(oldCreator.address);
    const afterNew_newCr  = await ledger.realFreeCollateral(newCreator.address);

    // Now the owner SHOULD have gained protocol fees from the new market
    expect(afterNew_owner).to.be.gt(afterOld_owner);

    // New creator also gains
    expect(afterNew_newCr).to.be.gt(afterOld_newCr);

    // Old creator might or might not have changed further depending on HWM behaviour,
    // but it should be at least as large as after the old-market trade.
    expect(afterNew_oldCr).to.be.gte(afterOld_oldCr);

    // Final invariants
    await expectCoreSystemInvariants(fx, {
      accounts: [
        traderSigner.address,
        mmAddr,
        oldCreator.address,
        newCreator.address,
        ledgerOwner.address,
      ],
      marketId: marketNew,
      checkRedeemabilityFor: [
        traderSigner.address,
        mmAddr,
        oldCreator.address,
        newCreator.address,
        ledgerOwner.address,
      ],
    });
  });
});
