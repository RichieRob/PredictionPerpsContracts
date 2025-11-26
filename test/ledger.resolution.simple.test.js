// test/ledger.resolution.simple.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, EMPTY_PERMIT } = require("./helpers/core");

describe("MarketMakerLedger – simple resolution + winnings claim", () => {
  let fx, mm, marketId, posA, posB;

  beforeEach(async () => {
    fx = await deployCore();

    // --- 1. Deploy MM (always tradeable) ---
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();
    await mm.waitForDeployment();

    // --- 2. Create resolving market (NOT DMM, NOT ISC) ---
    await fx.ledger.createMarket(
      "Election 2028",
      "EL",
      ethers.ZeroAddress,   // resolving market → no DMM
      0,                    // no ISC
      true,                 // resolves
      fx.owner.address,     // oracle
      "0x"
    );

    marketId = (await fx.ledger.getMarkets())[0];

    // --- 3. Two positions ---
    await fx.ledger.createPosition(marketId, "Alice", "A");
    await fx.ledger.createPosition(marketId, "Bob",   "B");
    const P = await fx.ledger.getMarketPositions(marketId);
    posA = P[0];
    posB = P[1];

    // --- 4. Trader funds ledger ---
    await fx.usdc.mint(fx.trader.address, usdc("1000"));
    await fx.usdc.connect(fx.trader).approve(await fx.ledger.getAddress(), usdc("1000"));
    
    await fx.ledger.connect(fx.trader).deposit(
      fx.trader.address,
      usdc("1000"),
      0,                 // min
      0,                 // MODE = allowance
      EMPTY_PERMIT,      // REQUIRED
      "0x"               // permit2
    );

// fund MM so it can take the short side
await fx.usdc.mint(fx.owner.address, usdc("2000"));
await fx.usdc.connect(fx.owner).approve(await fx.ledger.getAddress(), usdc("2000"));

await fx.ledger.connect(fx.owner).deposit(
  await mm.getAddress(),   // <— FUND THE MM AS COUNTERPARTY
  usdc("1500"),            // enough to cover short side of trade
  0,
  0,
  EMPTY_PERMIT,
  "0x"
);



    // --- 5. Buy tokens from MARKET MAKER ---
    await fx.ledger.connect(fx.trader).buyExactTokens(
      await mm.getAddress(),
      marketId,
      posA,
      true,             // back
      usdc("200"),      // buy 200 tokens
      usdc("1000")      // max spend
    );
  });

  it("resolves → trader claims winnings → invariants preserved", async () => {

    // ====== MANUAL RESOLUTION ======
    await fx.ledger["resolveMarket(uint256,uint256)"](marketId, posA);

    // ====== CLAIM ======
    await fx.ledger.connect(fx.trader).claimAllPendingWinnings();

    const winnings = await fx.ledger.realFreeCollateral(fx.trader.address);
    expect(winnings).to.be.gt(0n);

    // invariants
    expect(
        await fx.ledger.invariant_checkSolvencyAllMarkets(fx.trader.address)
    ).to.equal(true);

    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(tvl).to.equal(aBal);

    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
});

});
