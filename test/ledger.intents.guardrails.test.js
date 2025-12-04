// test/ledger.intents.guardrails.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");
const { signIntent } = require("./helpers/intents");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("MarketMakerLedger – intent guardrails", () => {
  let fx;   // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let mm;   // FlatMockMarketMaker

  beforeEach(async () => {
    fx = await deployCore();

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    // Allow mm as DMM
    await fx.ledger.allowDMM(await mm.getAddress(), true);

    // Simple market, no ISC
    await fx.ledger.createMarket(
      "Intent Guardrail Market",
      "IGM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"    );

    const markets = await fx.ledger.getMarkets();
    fx.marketId = markets[0];

    // One position is enough
    await fx.ledger.createPosition(fx.marketId, "Outcome A", "OA");

    // Give both trader + owner some freeCollateral
    // Trader
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
        0,
        EMPTY_PERMIT
      );

    // Owner (filler)
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
  });

  async function buildBaseIntent(overrides = {}) {
    const positions = await fx.ledger.getMarketPositions(fx.marketId);
    const positionId = positions[0];

    const base = {
      trader:        fx.trader.address,
      marketId:      fx.marketId,
      positionId,
      isBack:        true,
      kind:          0,              // BUY_EXACT_TOKENS
      primaryAmount: usdc("10"),
      bound:         usdc("1000"),
      nonce:         1n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    return { ...base, ...overrides };
  }

  it("cannot fill a cancelled intent", async () => {
    const intent = await buildBaseIntent();
    const sig = await signIntent(fx.ledger, fx.trader, intent);

    // Trader cancels first
    await fx.ledger.connect(fx.trader).cancelIntent(intent);

    // Now filler (owner) tries to fill – should revert
    await expect(
      fx.ledger
        .connect(fx.owner)
        .fillIntent(
          intent,
          sig,
          intent.primaryAmount,
          intent.bound
        )
    ).to.be.reverted;

    // Invariants still fine
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, fx.owner.address, await mm.getAddress()],
      marketId: fx.marketId,
      checkRedeemabilityFor: [fx.trader.address, fx.owner.address],
    });
  });

  it("cannot fill an intent with a bad signer", async () => {
    const intent = await buildBaseIntent();

    // ❌ Signature from wrong signer (owner instead of trader)
    const badSig = await signIntent(fx.ledger, fx.owner, intent);

    await expect(
      fx.ledger
        .connect(fx.owner)
        .fillIntent(
          intent,
          badSig,
          intent.primaryAmount,
          intent.bound
        )
    ).to.be.reverted;

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, fx.owner.address, await mm.getAddress()],
      marketId: fx.marketId,
      checkRedeemabilityFor: [fx.trader.address, fx.owner.address],
    });
  });

  it("cannot fill an expired intent", async () => {
    const now = Math.floor(Date.now() / 1000);

    const intent = await buildBaseIntent({
      deadline: BigInt(now - 60), // already expired
    });

    const sig = await signIntent(fx.ledger, fx.trader, intent);

    await expect(
      fx.ledger
        .connect(fx.owner)
        .fillIntent(
          intent,
          sig,
          intent.primaryAmount,
          intent.bound
        )
    ).to.be.reverted;

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, fx.owner.address, await mm.getAddress()],
      marketId: fx.marketId,
      checkRedeemabilityFor: [fx.trader.address, fx.owner.address],
    });
  });
});
