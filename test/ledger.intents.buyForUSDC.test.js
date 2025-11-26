// test/ledger.intents.buyForUSDC.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");
const { signIntent } = require("./helpers/intents");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("MarketMakerLedger – BUY_FOR_USDC intents", () => {
  let fx;   // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let mm;   // FlatMockMarketMaker (also DMM)

  beforeEach(async () => {
    fx = await deployCore();

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    // Allow mm as DMM
    await fx.ledger.allowDMM(await mm.getAddress(), true);

    // Simple market with this mm as DMM, no ISC
    await fx.ledger.createMarket(
      "Intent BUY_FOR_USDC Market",
      "BFUM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"
    );

    const markets = await fx.ledger.getMarkets();
    fx.marketId = markets[0];

    // One position is enough
    await fx.ledger.createPosition(fx.marketId, "Outcome A", "OA");
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    fx.positionId = positions[0];

    // --- Seed DMM free collateral so solvency checks on mm are safe ---

    await fx.usdc.mint(fx.owner.address, usdc("500000")); // 500k USDC
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("500000"));

    await fx.ledger
      .connect(fx.owner)
      .deposit(
        await mm.getAddress(),   // DMM account
        usdc("500000"),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // --- Give filler (owner) some BACK inventory to sell P2P ---

    await fx.usdc.mint(fx.owner.address, usdc("1000"));
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("1000"));

    await fx.ledger
      .connect(fx.owner)
      .deposit(
        fx.owner.address,
        usdc("1000"),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Owner buys 40 BACK tokens from DMM so they have inventory
    await fx.ledger
      .connect(fx.owner)
      .buyExactTokens(
        await mm.getAddress(),
        fx.marketId,
        fx.positionId,
        true,          // isBack
        usdc("40"),    // 40 tokens (6 decimals)
        usdc("1000")   // maxUSDCIn
      );

    // --- Trader gets freeCollateral but no positions initially ---

    await fx.usdc.mint(fx.trader.address, usdc("500"));
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), usdc("500"));

    await fx.ledger
      .connect(fx.trader)
      .deposit(
        fx.trader.address,
        usdc("500"),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );
  });

  async function buildBaseIntent(overrides = {}) {
    const base = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId:    fx.positionId,
      isBack:        true,
      kind:          1,              // BUY_FOR_USDC
      primaryAmount: usdc("50"),     // trader wants to spend up to 50 USDC
      bound:         usdc("5"),      // minTokensOut (very relaxed)
      nonce:         1n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    return { ...base, ...overrides };
  }

  it("fills a BUY_FOR_USDC intent and preserves invariants", async () => {
    const intent = await buildBaseIntent();

    // Sign intent with trader key
    const sig = await signIntent(fx.ledger, fx.trader, intent);

    const traderFreeBefore = await fx.ledger.realFreeCollateral(
      fx.trader.address
    );

    // Filler (owner) executes the intent
    await fx.ledger
      .connect(fx.owner)
      .fillIntent(
        intent,
        sig,
        intent.primaryAmount,  // fillPrimary = 50 USDC
        intent.bound           // fillQuote   = minTokensOut (5)
      );

    const traderFreeAfter = await fx.ledger.realFreeCollateral(
      fx.trader.address
    );

    // Trader should have spent some freeCollateral (or equal in degenerate case)
    expect(traderFreeAfter).to.be.at.most(traderFreeBefore);

    // 🔨 Hammer invariants system-wide
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, fx.owner.address, await mm.getAddress()],
      marketId: fx.marketId,
      checkRedeemabilityFor: [fx.trader.address, fx.owner.address],
    });
  });
});
