// test/ledger.resolution.simple.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, EMPTY_PERMIT, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");
const { resolveViaMockOracle } = require("./helpers/resolution");

describe("MarketMakerLedger – simple resolution + winnings claim", () => {
  let fx, mm, marketId, posA, posB;

  beforeEach(async () => {
    fx = await deployCore();

    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();
    await mm.waitForDeployment();

    // Use owner as a dumb oracle (no MockOracle here)
    await fx.ledger.createMarket(
      "Election 2028",
      "EL",
      ethers.ZeroAddress,   // resolving market → no DMM
      0,                    // no ISC
      true,                 // resolves
      fx.owner.address,     // oracle (unused, but stored)
      "0x"    );

    marketId = (await fx.ledger.getMarkets())[0];

    await fx.ledger.createPosition(marketId, "Alice", "A");
    await fx.ledger.createPosition(marketId, "Bob",   "B");
    const P = await fx.ledger.getMarketPositions(marketId);
    posA = P[0];
    posB = P[1];

    // trader deposit via helper
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: usdc("1000"),
    });

    // MM deposit via helper
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.owner,
      to: await mm.getAddress(),
      amount: usdc("1500"),
    });

    // trader buys some A
    await fx.ledger.connect(fx.trader).buyExactTokens(
      await mm.getAddress(),
      marketId,
      posA,
      true,
      usdc("200"),
      usdc("1000")
    );
  });

  it("resolves → trader claims winnings → invariants preserved", async () => {
    // manual resolution (overloaded function, no oracle helper here)
    await fx.ledger["resolveMarket(uint256,uint256)"](marketId, posA);

    await fx.ledger.connect(fx.trader).claimAllPendingWinnings();

    const winnings = await fx.ledger.realFreeCollateral(fx.trader.address);
    expect(winnings).to.be.gt(0n);

    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [fx.trader.address, await mm.getAddress()],
    });
  });
});
