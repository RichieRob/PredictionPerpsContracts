// test/ledger.resolution.simple.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, EMPTY_PERMIT } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");

describe("MarketMakerLedger – simple resolution + winnings claim", () => {
  let fx, mm, marketId, posA, posB;

  beforeEach(async () => {
    fx = await deployCore();
    const { owner, ledger } = fx;

    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();
    await mm.waitForDeployment();

    // Resolving market with no DMM (we still trade via mm as an external DMM)
    await ledger
      .connect(owner)
      .createMarket(
        "Election 2028",
        "EL",
        ethers.ZeroAddress,   // no DMM registered on ledger
        0,                    // no ISC
        true,                 // doesResolve
        owner.address,        // oracle (unused in this simple test)
        "0x",
        0,                    // feeBps
        owner.address,        // marketCreator
        [],                   // feeWhitelistAccounts
        false                 // hasWhitelist
      );

    marketId = (await ledger.getMarkets())[0];

    await ledger.connect(owner).createPosition(marketId, "Alice", "A");
    await ledger.connect(owner).createPosition(marketId, "Bob", "B");
    const P = await ledger.getMarketPositions(marketId);
    posA = P[0];
    posB = P[1];

    // trader funded
    await fx.usdc.mint(fx.trader.address, usdc("1000"));
    await fx.usdc
      .connect(fx.trader)
      .approve(await ledger.getAddress(), usdc("1000"));
    await ledger
      .connect(fx.trader)
      .deposit(fx.trader.address, usdc("1000"), 0, 0, EMPTY_PERMIT);

    // MM funded so it can sell
    await fx.usdc.mint(fx.owner.address, usdc("1500"));
    await fx.usdc
      .connect(fx.owner)
      .approve(await ledger.getAddress(), usdc("1500"));
    await ledger
      .connect(fx.owner)
      .deposit(await mm.getAddress(), usdc("1500"), 0, 0, EMPTY_PERMIT);

    // trader buys some A
    await ledger.connect(fx.trader).buyExactTokens(
      await mm.getAddress(),
      marketId,
      posA,
      true,
      usdc("200"),
      usdc("1000")
    );
  });

  it("resolves → trader claims winnings → invariants preserved", async () => {
    const { ledger, trader } = fx;

    // manual resolution (winner = posA)
    await ledger["resolveMarket(uint256,uint256)"](marketId, posA);

    // NEW API: batchClaimWinnings(account, marketIds)
    await ledger
      .connect(trader)
      .batchClaimWinnings(trader.address, [marketId]);

    const winnings = await ledger.realFreeCollateral(trader.address);
    expect(winnings).to.be.gt(0n);

    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [trader.address, await mm.getAddress()],
    });
  });
});
