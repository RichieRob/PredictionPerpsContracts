// test/ledger.intents.fail.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");
const { signIntent } = require("./helpers/intents");

describe("MarketMakerLedger – intents (failure cases)", () => {
  let fx;
  let mm;

  beforeEach(async () => {
    fx = await deployCore();

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    await fx.ledger.allowDMM(await mm.getAddress(), true);

    await fx.ledger.createMarket(
      "Intent Market",
      "INTM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
  "0x",
  0,                             // feeBps
  fx.owner.address,              // marketCreator
  [],                            // feeWhitelistAccounts
  false                          // hasWhitelist
);
    const markets = await fx.ledger.getMarkets();
    fx.marketId = markets[0];

    await fx.ledger.createPosition(fx.marketId, "Outcome A", "OA");

    const funding = usdc("1000");

    // trader
    await fx.usdc.mint(fx.trader.address, funding);
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), funding);
    await fx.ledger
      .connect(fx.trader)
      .deposit(
        fx.trader.address,
        funding,
        0,
        0,
        EMPTY_PERMIT
      );

    // filler (owner)
    await fx.usdc.mint(fx.owner.address, funding);
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), funding);
    await fx.ledger
      .connect(fx.owner)
      .deposit(
        fx.owner.address,
        funding,
        0,
        0,
        EMPTY_PERMIT
      );
  });

  it("reverts on filling a cancelled intent", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const intent = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          0, // BUY_EXACT_TOKENS
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         1n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const sig = await signIntent(fx.intentContract, fx.trader, intent);

    await fx.intentContract.connect(fx.trader).cancelIntent(intent);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(intent, sig, intent.primaryAmount, intent.bound)
    ).to.be.reverted;
  });

  it("reverts on filling with bad signer", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const intent = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          0,
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         2n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    // bad signer: owner signs instead of trader
    const badSig = await signIntent(fx.intentContract, fx.owner, intent);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(intent, badSig, intent.primaryAmount, intent.bound)
    ).to.be.reverted;
  });

  it("reverts on filling expired intent", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const intent = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          0,
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         3n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) - 3600), // expired
    };

    const sig = await signIntent(fx.intentContract, fx.trader, intent);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(intent, sig, intent.primaryAmount, intent.bound)
    ).to.be.reverted;
  });

  it("reverts SELL_* kinds in intents", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const sellExact = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          2,              // SELL_EXACT_TOKENS
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         4n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const sigSellExact = await signIntent(fx.intentContract, fx.trader, sellExact);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(
          sellExact,
          sigSellExact,
          sellExact.primaryAmount,
          sellExact.bound
        )
    ).to.be.reverted;

    const sellFor = {
      ...sellExact,
      kind: 3,  // SELL_FOR_USDC
      nonce: 5n,
    };

    const sigSellFor = await signIntent(fx.intentContract, fx.trader, sellFor);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(
          sellFor,
          sigSellFor,
          sellFor.primaryAmount,
          sellFor.bound
        )
    ).to.be.reverted;
  });

  it("reverts unknown kind values", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const intent = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          99,             // nonsense
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         6n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const sig = await signIntent(fx.intentContract, fx.trader, intent);

    await expect(
      fx.intentContract
        .connect(fx.owner)
        .fillIntent(intent, sig, intent.primaryAmount, intent.bound)
    ).to.be.reverted;
  });
});
