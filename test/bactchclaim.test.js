// test/resolution.batchClaim.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("MarketMakerLedger – batchClaimWinnings", () => {
  let fx;
  let mm;
  let marketId;
  let posA;

  beforeEach(async () => {
    fx = await deployCore();

    // Flat MM used purely as counterparty, NOT as DMM in the market struct
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();
    await mm.waitForDeployment();

    // Resolving market → dmm = ZeroAddress
    await fx.ledger.createMarket(
      "Batch Claim Election",
      "BCE",
      ethers.ZeroAddress,   // 👈 no DMM for resolving markets
      0,                    // no ISC
      true,                 // doesResolve = true
      fx.owner.address,     // dummy oracle address
      "0x"    );

    marketId = (await fx.ledger.getMarkets())[0];

    // Two positions: A (winner), B (loser)
    await fx.ledger.createPosition(marketId, "Alice", "A");
    await fx.ledger.createPosition(marketId, "Bob",   "B");
    const P = await fx.ledger.getMarketPositions(marketId);
    posA = P[0];

    // Trader deposit via helper
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: usdc("1000"),
    });

    // MM deposit via helper (backing capital)
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.owner,
      to: await mm.getAddress(),
      amount: usdc("1500"),
    });

    // Trader buys some A from mm
    await fx.ledger.connect(fx.trader).buyExactTokens(
      await mm.getAddress(),
      marketId,
      posA,
      true,
      usdc("200"),
      usdc("1000")
    );
  });

  it("runs batchClaimWinnings after resolution and keeps invariants", async () => {
    const trader = fx.trader.address;
    const mmAddr = await mm.getAddress();

    // Resolve manually: A wins
    await fx.ledger["resolveMarket(uint256,uint256)"](marketId, posA);

    const realBefore = await fx.ledger.realFreeCollateral(trader);
    const effBefore  = await fx.ledger.effectiveFreeCollateral(trader);

    // Main call under test
    await fx.ledger.batchClaimWinnings(trader, [marketId]);

    const realAfter = await fx.ledger.realFreeCollateral(trader);
    const effAfter  = await fx.ledger.effectiveFreeCollateral(trader);

    // 1) We never lose collateral by claiming
    expect(realAfter).to.be.gte(realBefore);

    // 2) effective freeCollateral is always >= real
    expect(effAfter).to.be.gte(realAfter);
    expect(effAfter).to.be.gte(0n);
    expect(realAfter).to.be.gte(0n);

    // 3) System-wide invariants still hold
    await expectCoreSystemInvariants(fx, {
      accounts: [trader, mmAddr],
      marketId,
      checkRedeemabilityFor: [trader, mmAddr],
    });
  });
});
