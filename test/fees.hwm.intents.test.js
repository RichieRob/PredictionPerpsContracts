// test/fees.hwm.intent.mmstyle.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");

// ---- EIP-712 signing helper using ethers v6 signTypedData ----

async function signIntent(traderSigner, intents, intent) {
  const { chainId } = await ethers.provider.getNetwork();
  const verifyingContract = await intents.getAddress();

  const domain = {
    name: "PredictionPerps-Intents",
    version: "1",
    chainId,
    verifyingContract,
  };

  const types = {
    Intent: [
      { name: "trader",        type: "address" },
      { name: "marketId",      type: "uint256" },
      { name: "positionId",    type: "uint256" },
      { name: "isBack",        type: "bool" },
      { name: "kind",          type: "uint8" },
      { name: "primaryAmount", type: "uint256" },
      { name: "bound",         type: "uint256" },
      { name: "nonce",         type: "uint256" },
      { name: "deadline",      type: "uint256" },
    ],
  };

  return traderSigner.signTypedData(domain, types, intent);
}

describe("FeeLib – intents with MM-style filler (ppUSDC-only)", () => {
  async function setupIntentEnv() {
    const fx = await deployCore();
    const { ledger } = fx;

    const [owner] = await ethers.getSigners();

    const IntentContract = await ethers.getContractFactory("IntentContract");
    const intents = await IntentContract.deploy(await ledger.getAddress());
    await intents.waitForDeployment();

    await ledger.connect(owner).setIntentContract(await intents.getAddress(), true);

    // Protocol share = 20% of the fee base for NEW markets
    await ledger
      .connect(owner)
      .setNewMarketProtocolFeeShareBps(2_000); // 20%

    return { fx, ledger, intents };
  }

  it("charges HWM fees to a non-whitelisted filler when using intents", async () => {
    const { fx, ledger, intents } = await setupIntentEnv();
    const { usdc: usdcToken } = fx;

    const signers = await ethers.getSigners();
    const owner         = signers[0];
    const filler        = signers[1]; // MM-style ppUSDC-only account
    const trader        = signers[2]; // submits intent
    const marketCreator = signers[3]; // market creator

    // ----------------------------------------------------------------
    // Create market WITHOUT whitelist
    // ----------------------------------------------------------------
    await ledger.connect(owner).createMarket(
      "Intent-NoWL",
      "INW",
      ethers.ZeroAddress, // no DMM
      usdc("0"),
      false,
      ethers.ZeroAddress,
      "0x",
      5_000,              // 50% fee
      marketCreator.address,
      [],
      false               // hasWhitelist = false
    );
    const marketId = (await ledger.getMarkets())[0];

    // Single YES position
    await ledger.connect(marketCreator).createPosition(marketId, "YES", "Y");
    const [positionId] = await ledger.getMarketPositions(marketId);

    // ----------------------------------------------------------------
    // Fund filler + trader with ppUSDC via deposit; no position tokens for filler
    // ----------------------------------------------------------------
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: filler,
      amount: usdc("2000"),
    });

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: trader,
      amount: usdc("2000"),
    });

    // Baseline fee state
    const beforeFiller  = await ledger.debugFeeState(filler.address, marketId);
    const beforeTrader  = await ledger.debugFeeState(trader.address, marketId);
    const beforeCreator = await ledger.debugFeeState(marketCreator.address, marketId);
    const beforeOwner   = await ledger.debugFeeState(owner.address, marketId);

    const primaryAmount = usdc("200");   // A tokens requested
    const bound         = usdc("1000");  // max USDC in
    const now = (await ethers.provider.getBlock("latest")).timestamp;

    const intent = {
      trader:        trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          0,           // BUY_EXACT_TOKENS
      primaryAmount,
      bound,
      nonce:         0,
      deadline:      now + 3600,
    };

    const sig = await signIntent(trader, intents, intent);

    const fillPrimary = primaryAmount;   // 200 tokens
    const fillQuote   = usdc("200");     // 200 ppUSDC quote

    await intents
      .connect(filler)
      .fillIntent(intent, sig, fillPrimary, fillQuote);

    const afterFiller  = await ledger.debugFeeState(filler.address, marketId);
    const afterTrader  = await ledger.debugFeeState(trader.address, marketId);
    const afterCreator = await ledger.debugFeeState(marketCreator.address, marketId);
    const afterOwner   = await ledger.debugFeeState(owner.address, marketId);

    const usdc200 = usdc("200");
    const usdc100 = usdc("100");
    const usdc80  = usdc("80");
    const usdc20  = usdc("20");

    // Filler's net allocation and HWM:
    // netAlloc = spent - redeemed = 200 - 0 = 200
    expect(afterFiller.spent - beforeFiller.spent).to.equal(usdc200);
    expect(afterFiller.redeemed - beforeFiller.redeemed).to.equal(0n);
    expect(afterFiller.hwm - beforeFiller.hwm).to.equal(usdc200);

    // FeeBase = 50% of ΔnetAlloc = 0.5 * 200 = 100
    // Creator gets 80 (40% of 200), protocol gets 20 (10% of 200)
    expect(afterCreator.realFree - beforeCreator.realFree).to.equal(usdc80);
    expect(afterOwner.realFree   - beforeOwner.realFree).to.equal(usdc20);

    // Filler loses exactly feeBase of free collateral
    expect(beforeFiller.realFree - afterFiller.realFree).to.equal(usdc100);

    // Trader pays 200 ppUSDC for the trade (no extra fee charged to them)
    expect(beforeTrader.realFree - afterTrader.realFree).to.equal(usdc200);
  });

  it("does not charge HWM fees to a whitelisted filler when using intents", async () => {
    const { fx, ledger, intents } = await setupIntentEnv();
    const { usdc: usdcToken } = fx;

    const signers = await ethers.getSigners();
    const owner         = signers[0];
    const filler        = signers[1]; // MM-style ppUSDC-only account
    const trader        = signers[2]; // submits intent
    const marketCreator = signers[3]; // market creator

    // ----------------------------------------------------------------
    // Create market WITH whitelist
    // ----------------------------------------------------------------
    await ledger.connect(owner).createMarket(
      "Intent-WL",
      "IW",
      ethers.ZeroAddress,
      usdc("0"),
      false,
      ethers.ZeroAddress,
      "0x",
      5_000,              // 50% fee
      marketCreator.address,
      [],
      true                // hasWhitelist = true
    );
    const marketId = (await ledger.getMarkets())[0];

    // Single YES position
    await ledger.connect(marketCreator).createPosition(marketId, "YES", "Y");
    const [positionId] = await ledger.getMarketPositions(marketId);

    // Whitelist filler for HWM fees on this market
    await ledger
      .connect(marketCreator)
      .setFeeWhitelist(marketId, filler.address, true);

    // Fund filler + trader with ppUSDC via deposit
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: filler,
      amount: usdc("2000"),
    });

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: trader,
      amount: usdc("2000"),
    });

    const beforeFiller  = await ledger.debugFeeState(filler.address, marketId);
    const beforeTrader  = await ledger.debugFeeState(trader.address, marketId);
    const beforeCreator = await ledger.debugFeeState(marketCreator.address, marketId);
    const beforeOwner   = await ledger.debugFeeState(owner.address, marketId);

    // Sanity: market has whitelist and filler is whitelisted
    expect(beforeFiller.hasWhitelist).to.equal(true);
    expect(beforeFiller.isWhitelisted).to.equal(true);

    const primaryAmount = usdc("200");
    const bound         = usdc("1000");
    const now = (await ethers.provider.getBlock("latest")).timestamp;

    const intent = {
      trader:        trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          0,           // BUY_EXACT_TOKENS
      primaryAmount,
      bound,
      nonce:         0,
      deadline:      now + 3600,
    };

    const sig = await signIntent(trader, intents, intent);

    const fillPrimary = primaryAmount;
    const fillQuote   = usdc("200");
    const usdc200     = usdc("200");

    await intents
      .connect(filler)
      .fillIntent(intent, sig, fillPrimary, fillQuote);

    const afterFiller  = await ledger.debugFeeState(filler.address, marketId);
    const afterTrader  = await ledger.debugFeeState(trader.address, marketId);
    const afterCreator = await ledger.debugFeeState(marketCreator.address, marketId);
    const afterOwner   = await ledger.debugFeeState(owner.address, marketId);

    // Filler is whitelisted → applyNetAllocationFee early-outs.
    // HWM should not move and filler should not lose freeCollateral from fees.
    expect(afterFiller.hwm).to.equal(beforeFiller.hwm);
    expect(afterFiller.realFree).to.equal(beforeFiller.realFree);

    // Creator/protocol should not receive any fee for this trade
    expect(afterCreator.realFree).to.equal(beforeCreator.realFree);
    expect(afterOwner.realFree).to.equal(beforeOwner.realFree);

    // Trader still pays the 200 ppUSDC quote leg for the trade
    expect(beforeTrader.realFree - afterTrader.realFree).to.equal(usdc200);
  });
});
