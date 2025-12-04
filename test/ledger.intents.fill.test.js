// test/ledger.intents.fill.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");
const { signIntent } = require("./helpers/intents");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("MarketMakerLedger – intents", () => {
  let fx;   // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let mm;   // FlatMockMarketMaker (also used as DMM / reference account)

  beforeEach(async () => {
    fx = await deployCore();

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    // Allow the mm contract as a DMM
    await fx.ledger.allowDMM(await mm.getAddress(), true);

    // Create a simple market with this mm as DMM, no ISC
    await fx.ledger.createMarket(
      "Intent Market",
      "INTM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"    );

    const markets = await fx.ledger.getMarkets();
    fx.marketId = markets[0];

    // One position is enough for this test
    await fx.ledger.createPosition(fx.marketId, "Outcome A", "OA");
  });

  it("fills a BUY_EXACT_TOKENS intent and preserves invariants", async () => {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    // --------------------------------------------------------------------
    // 1) Give BOTH trader and filler some freeCollateral in the ledger
    //    so P2P settlement can allocate capital without reverting.
    // --------------------------------------------------------------------

    // Trader: mint + deposit 1,000 USDC
    await fx.usdc.mint(fx.trader.address, usdc("1000"));
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), usdc("1000"));

    await fx.ledger
      .connect(fx.trader)
      .deposit(
        fx.trader.address,
        usdc("1000"),
        0,
        0,                 // mode = allowance
        EMPTY_PERMIT
      );

    // Filler (relayer) = owner in this test
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
        EMPTY_PERMIT
      );

    const beforeTraderFree = await fx.ledger.realFreeCollateral(
      fx.trader.address
    );
    const beforeOwnerFree = await fx.ledger.realFreeCollateral(
      fx.owner.address
    );

    // --------------------------------------------------------------------
    // 2) Build a BUY_EXACT_TOKENS intent for the trader
    // --------------------------------------------------------------------
    const intent = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          0,                  // Types.TradeKind.BUY_EXACT_TOKENS
      primaryAmount: usdc("10"),         // “10 tokens” in your 6-dec scale
      bound:         usdc("1000"),       // max quote / ppUSDC
      nonce:         1n,
      deadline:      BigInt(
        Math.floor(Date.now() / 1000) + 3600 // +1h
      ),
    };

    const sig = await signIntent(fx.ledger, fx.trader, intent);

    // Filler will be fx.owner (we call fillIntent via .connect(fx.owner))
    const beforeOwnerWallet = await fx.usdc.balanceOf(fx.owner.address);
    const beforeTraderWallet = await fx.usdc.balanceOf(fx.trader.address);

    // --------------------------------------------------------------------
    // 3) Fill the intent on-chain
    // --------------------------------------------------------------------
    await fx.ledger
      .connect(fx.owner)
      .fillIntent(
        intent,
        sig,
        intent.primaryAmount,  // fillPrimary = full size
        intent.bound           // fillQuote cap; FillIntentLib will enforce pricing
      );

    // --------------------------------------------------------------------
    // 4) Basic sanity + invariants
    // --------------------------------------------------------------------

    // Free collateral should have moved between parties, but be non-negative
    const afterTraderFree = await fx.ledger.realFreeCollateral(
      fx.trader.address
    );
    const afterOwnerFree = await fx.ledger.realFreeCollateral(
      fx.owner.address
    );

    expect(afterTraderFree).to.be.gte(0n);
    expect(afterOwnerFree).to.be.gte(0n);

    // Optional: check at least one party’s freeCollateral changed
    expect(
      afterTraderFree !== beforeTraderFree ||
      afterOwnerFree !== beforeOwnerFree
    ).to.equal(true);

    // Hammer your core invariants (solvency, TVL, system balance, etc.)
    await expectCoreSystemInvariants(fx, {
      accounts: [
        fx.trader.address,
        fx.owner.address,
        await mm.getAddress(),
      ],
      marketId: fx.marketId,
      checkRedeemabilityFor: [fx.trader.address, fx.owner.address],
    });
  });
});
