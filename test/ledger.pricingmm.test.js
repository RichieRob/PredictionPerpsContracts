// test/ledger.pricingmm.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { deployCore, usdc } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");

describe("Ledger – pricingMarketMaker", function () {
  it("defaults pricing MM to DMM when unset (existing LMSR fixture market)", async () => {
    const fx = await setupLmsrLedgerFixture();
    const { ledger, lmsr, marketId } = fx;

    const pricing = await ledger.getPricingMM(marketId);
    expect(pricing).to.equal(await lmsr.getAddress());
  });

  it("only marketCreator can setPricingMarketMaker; getter returns override", async () => {
    const fx = await setupLmsrLedgerFixture();
    const { owner, other, ledger, lmsr, marketId } = fx;

    // Before: fallback to DMM
    expect(await ledger.getPricingMM(marketId)).to.equal(await lmsr.getAddress());

    // Non-creator should revert (don’t pin revert string since you might change it)
    await expect(
      ledger.connect(other).setPricingMarketMaker(marketId, other.address)
    ).to.be.reverted;

    // Creator can set it
    await expect(
      ledger.connect(owner).setPricingMarketMaker(marketId, other.address)
    )
      .to.emit(ledger, "PricingMarketMakerSet")
      .withArgs(marketId, other.address);

    // After: override wins
    expect(await ledger.getPricingMM(marketId)).to.equal(other.address);
  });

  it("if DMM is zero, pricingMM is zero until explicitly set", async () => {
    const fx = await deployCore();
    const { owner, ledger } = fx;

    // Create an LMSR contract just to have a real mm address for later
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    const lmsr = await LMSR.deploy(owner.address, await ledger.getAddress());
    await lmsr.waitForDeployment();

    const lmsrAddr = await lmsr.getAddress();
    await ledger.connect(owner).allowDMM(lmsrAddr, true);

    // Create market with DMM = 0
    await ledger.connect(owner).createMarket(
      "Zero DMM Market",
      "ZDM",
      ethers.ZeroAddress,  // dmm
      0n,                  // iscAmount
      false,               // doesResolve
      ethers.ZeroAddress,  // oracle
      "0x",                // oracleParams
      0,                   // feeBps
      owner.address,       // marketCreator
      [],                  // whitelist
      false
    );

    const markets = await ledger.getMarkets();
    const marketId = markets[markets.length - 1];

    expect(await ledger.getPricingMM(marketId)).to.equal(ethers.ZeroAddress);

    // Now set pricing mm explicitly
    await (await ledger.connect(owner).setPricingMarketMaker(marketId, lmsrAddr)).wait();
    expect(await ledger.getPricingMM(marketId)).to.equal(lmsrAddr);
  });
});
