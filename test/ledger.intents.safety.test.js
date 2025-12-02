// test/ledger.intents.safety.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

const TradeKind = {
  BUY_EXACT_TOKENS: 0,
  BUY_FOR_USDC: 1,
  SELL_EXACT_TOKENS: 2,
  SELL_FOR_USDC: 3,
};

const INTENT_TYPES = {
  Intent: [
    { name: "trader",        type: "address" },
    { name: "marketId",      type: "uint256" },
    { name: "positionId",    type: "uint256" },
    { name: "isBack",        type: "bool"    },
    { name: "kind",          type: "uint8"   },
    { name: "primaryAmount", type: "uint256" },
    { name: "bound",         type: "uint256" },
    { name: "nonce",         type: "uint256" },
    { name: "deadline",      type: "uint256" },
  ],
};

describe("MarketMakerLedger – intent safety (cancel, expiry, bad sig)", function () {
  let fx;         // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let mm;         // FlatMockMarketMaker (DMM)
  let other;      // extra signer for bad sig test
  let marketId;
  let positionId;
  let domain;

  beforeEach(async () => {
    fx = await deployCore();
    const signers = await ethers.getSigners();
    // deployCore uses [owner, trader, feeRecipient, ...]
    other = signers[3];

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    // Allow mm as DMM
    await fx.ledger.allowDMM(await mm.getAddress(), true);

    // Simple market + one position
    await fx.ledger.createMarket(
      "Intent Safety Market",
      "ISM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"    );

    const markets = await fx.ledger.getMarkets();
    marketId = markets[0];

    await fx.ledger.createPosition(marketId, "Outcome A", "OA");
    const positions = await fx.ledger.getMarketPositions(marketId);
    positionId = positions[0];

    // --- Seed DMM + trader collateral so fills *could* succeed if allowed ---

    // Owner funds mm (DMM) for redeemability
    await fx.usdc.mint(fx.owner.address, usdc("1000000"));
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("1000000"));

    await fx.ledger
      .connect(fx.owner)
      .deposit(
        await mm.getAddress(),
        usdc("500000"),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Trader has some collateral to spend against intents
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
        EMPTY_PERMIT,
        "0x"
      );

    // EIP-712 domain for this ledger
    const { chainId } = await ethers.provider.getNetwork();
    domain = {
      name: "PredictionPerps-Intents",
      version: "1",
      chainId,
      verifyingContract: await fx.ledger.getAddress(),
    };
  });

  async function signIntent(signer, intent) {
    // ethers v6
    return signer.signTypedData(domain, INTENT_TYPES, intent);
  }

  it("cannot fill a cancelled intent", async function () {
    const intent = {
      trader:        fx.trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          TradeKind.BUY_EXACT_TOKENS,
      primaryAmount: usdc("10"),   // 10 tokens
      bound:         usdc("1000"), // max USDC
      nonce:         1n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const sig = await signIntent(fx.trader, intent);

    // Trader cancels BEFORE any fill
    await fx.ledger.connect(fx.trader).cancelIntent(intent);

    // Now any attempt to fill must revert
    await expect(
      fx.ledger
        .connect(fx.owner) // relayer
        .fillIntent(intent, sig, usdc("5"), usdc("50"))
    ).to.be.reverted;

    // State is unchanged in terms of system invariants
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });
  });

  it("cannot fill an expired intent", async function () {
    const expiredDeadline = BigInt(Math.floor(Date.now() / 1000) - 60); // 1m in the past

    const intent = {
      trader:        fx.trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          TradeKind.BUY_FOR_USDC,
      primaryAmount: usdc("200"), // wants to spend up to 200 USDC
      bound:         0n,
      nonce:         2n,
      deadline:      expiredDeadline,
    };

    const sig = await signIntent(fx.trader, intent);

    await expect(
      fx.ledger
        .connect(fx.owner)
        .fillIntent(intent, sig, usdc("50"), usdc("5"))
    ).to.be.reverted;

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });
  });

  it("rejects signatures from the wrong signer (bad sig)", async function () {
    // Intent says trader = fx.trader, but we'll sign with `other`
    const intent = {
      trader:        fx.trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          TradeKind.BUY_EXACT_TOKENS,
      primaryAmount: usdc("5"),
      bound:         usdc("500"),
      nonce:         3n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    // Wrong signer
    const badSig = await signIntent(other, intent);

    await expect(
      fx.ledger
        .connect(fx.owner)
        .fillIntent(intent, badSig, usdc("5"), usdc("50"))
    ).to.be.reverted;

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });
  });
});
