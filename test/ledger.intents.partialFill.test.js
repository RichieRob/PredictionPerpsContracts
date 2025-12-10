// test/ledger.intents.partialFill.test.js
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

describe("MarketMakerLedger – partial fills for BUY_FOR_USDC intents", function () {
  let fx;   // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger, intentContract }
  let mm;   // FlatMockMarketMaker (DMM)
  let marketId;
  let positionId;
  let domain;

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
      "Intent Partial Fill Market",
      "IPFM",
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
    marketId = markets[0];

    // One position is enough for intents testing
    await fx.ledger.createPosition(marketId, "Outcome A", "OA");
    const positions = await fx.ledger.getMarketPositions(marketId);
    positionId = positions[0];

    // --- Seed DMM + RELAYER free collateral for solvency ---

    // Give owner a big USDC balance to fund both mm (DMM) and the relayer account itself
    await fx.usdc.mint(fx.owner.address, usdc("2000000")); // 2m USDC total
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("2000000"));

    // 1) Deposit on behalf of the DMM (mm address) so mm has freeCollateral
    await fx.ledger
      .connect(fx.owner)
      .deposit(
        await mm.getAddress(),   // to = DMM account
        usdc("500000"),          // 500k USDC
        0,
        0,
        EMPTY_PERMIT
      );

    // 2) Deposit on behalf of the relayer/filler (owner address) so it can take the other side of intents
    await fx.ledger
      .connect(fx.owner)
      .deposit(
        fx.owner.address,        // relayer account
        usdc("500000"),          // 500k USDC
        0,
        0,
        EMPTY_PERMIT
      );

    // --- Trader collateral for intent settlement ---
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

    // --- EIP-712 domain for this IntentContract (NOT the ledger!) ---
    const { chainId } = await ethers.provider.getNetwork();
    domain = {
      name: "PredictionPerps-Intents",
      version: "1",
      chainId,
      verifyingContract: await fx.intentContract.getAddress(),
    };
  });

  async function signIntent(intent) {
    // ethers v6: signer.signTypedData(domain, types, value)
    return fx.trader.signTypedData(domain, INTENT_TYPES, intent);
  }

  it("supports multiple partial fills up to primaryAmount and rejects overfill", async function () {
    // Canonical BUY_FOR_USDC intent:
    //  - trader spends up to 200 USDC
    //  - bound = 0 => no minTokens constraint in this test
    const intent = {
      trader:        fx.trader.address,
      marketId,
      positionId,
      isBack:        true,
      kind:          TradeKind.BUY_FOR_USDC,
      primaryAmount: usdc("200"),  // total USDC capacity
      bound:         0n,           // no minTokensOut constraint here
      nonce:         1n,
      deadline:      BigInt(Math.floor(Date.now() / 1000) + 3600),
    };

    const sig = await signIntent(intent);

    const relayer = fx.owner; // filler / relayer account

    // --- First partial fill: 80 USDC for 8 "tokens" (arbitrary ratio) ---
    const fill1Primary = usdc("80");
    const fill1Quote   = usdc("8");

    await fx.intentContract
      .connect(relayer)
      .fillIntent(intent, sig, fill1Primary, fill1Quote);

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });

    // --- Second partial fill: remaining 120 USDC for 12 tokens ---
    const fill2Primary = usdc("120");
    const fill2Quote   = usdc("12");

    await fx.intentContract
      .connect(relayer)
      .fillIntent(intent, sig, fill2Primary, fill2Quote);

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });

    // --- Attempting to overfill beyond primaryAmount must revert ---
    const overPrimary = usdc("1");
    const overQuote   = usdc("1");

    await expect(
      fx.intentContract
        .connect(relayer)
        .fillIntent(intent, sig, overPrimary, overQuote)
    ).to.be.reverted;

    // Final invariants after all attempts
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [await mm.getAddress()],
    });
  });
});
