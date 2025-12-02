// test/ledger.resolution.oracle.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, EMPTY_PERMIT } = require("./helpers/core");

describe("MarketMakerLedger – Oracle driven resolution", () => {
  let fx, mm, oracle, marketId, posA, posB;

  beforeEach(async () => {
    fx = await deployCore();

    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();   // tradeable but not DMM
    await mm.waitForDeployment();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    oracle = await MockOracle.deploy();
    await oracle.waitForDeployment();

    await fx.ledger.createMarket(
      "Election 2032",
      "EL32",
      ethers.ZeroAddress,
      0,
      true,
      oracle.getAddress(),
      "0x",
      false
    );

    marketId = (await fx.ledger.getMarkets())[0];

    await fx.ledger.createPosition(marketId, "Alice", "A");
    await fx.ledger.createPosition(marketId, "Bob", "B");
    const P = await fx.ledger.getMarketPositions(marketId);
    posA=P[0]; posB=P[1];

    // trader funded
    await fx.usdc.mint(fx.trader.address, usdc("1000"));
    await fx.usdc.connect(fx.trader).approve(await fx.ledger.getAddress(), usdc("1000"));
    await fx.ledger.connect(fx.trader).deposit(fx.trader.address, usdc("1000"),0,0,EMPTY_PERMIT,"0x");

    // MM funded so it can sell
    await fx.usdc.mint(fx.owner.address, usdc("2000"));
    await fx.usdc.connect(fx.owner).approve(await fx.ledger.getAddress(), usdc("2000"));
    await fx.ledger.connect(fx.owner).deposit(await mm.getAddress(), usdc("1500"),0,0,EMPTY_PERMIT,"0x");

    // buy Alice shares
    await fx.ledger.connect(fx.trader).buyExactTokens(
      await mm.getAddress(), marketId, posA, true, usdc("200"), usdc("1000")
    );
  });

  it("resolves via oracle + trader claims winnings + invariants ok", async () => {

    // ORACLE PUSHES RESULTS
    await oracle.pushResolution(marketId,posA);

    // LEDGER QUERIES ORACLE & RESOLVES
    await fx.ledger["resolveMarket(uint256)"](marketId);

    // Claim winnings
    await fx.ledger.connect(fx.trader).claimAllPendingWinnings();

    const win = await fx.ledger.realFreeCollateral(fx.trader.address);
    expect(win).to.be.gt(0n);

    // 🔥 all invariants intact
    expect(await fx.ledger.invariant_checkSolvencyAllMarkets(fx.trader.address)).to.equal(true);

    const [tvl,bal]=await fx.ledger.invariant_tvl();
    expect(tvl).to.equal(bal);

    const [lhs,rhs]=await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });
});
