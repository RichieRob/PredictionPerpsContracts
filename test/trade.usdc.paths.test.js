// test/ledger.usdc.tradepaths.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");

describe("MarketMakerLedger – USDC trade paths", function () {
  let fx;   // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let mm;   // FlatMockMarketMaker (also used as DMM)

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
      "USDC Trade Market",
      "UTM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"
    );

    const markets = await fx.ledger.getMarkets();
    fx.marketId = markets[0];

    // Two positions just to have >1 in the heap structures
    await fx.ledger.createPosition(fx.marketId, "Outcome A", "OA");
    await fx.ledger.createPosition(fx.marketId, "Outcome B", "OB");

    // --- Seed DMM free collateral so ensureSolvency can allocate() ---

    // Give owner a big USDC balance to fund the DMM
    await fx.usdc.mint(fx.owner.address, usdc("1000000")); // 1m USDC
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("1000000"));

    // Deposit on behalf of the DMM (mm address) so mm has freeCollateral
    await fx.ledger
      .connect(fx.owner)
      .deposit(
        await mm.getAddress(),   // to = DMM account
        usdc("500000"),          // 500k USDC
        0,                       // minUSDCDeposited
        0,                       // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );
  });

  async function getFirstMarketAndPositionIds() {
    const markets   = await fx.ledger.getMarkets();
    const marketId  = markets[0];
    const positions = await fx.ledger.getMarketPositions(marketId);
    const positionId = positions[0]; // Outcome A
    return { marketId, positionId };
  }

  it("buyExactTokensWithUSDC path works and preserves invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Trader gets some USDC in their wallet
    await fx.usdc.mint(fx.trader.address, usdc("1000")); // 1000 USDC
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), usdc("1000"));

    const beforeWallet = await fx.usdc.balanceOf(fx.trader.address);

    // Trader buys 10 tokens of Outcome A with USDC directly from wallet
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokensWithUSDC(
        await mm.getAddress(), // mm = FlatMockMarketMaker (also DMM account)
        marketId,
        positionId,
        true,                // isBack
        usdc("10"),          // 10 tokens (6 decimals)
        usdc("1000"),        // maxUSDCFromWallet (more than enough)
        0,                   // mode = allowance
        EMPTY_PERMIT,
        "0x"                 // permit2Calldata
      );

    const afterWallet = await fx.usdc.balanceOf(fx.trader.address);
    expect(afterWallet).to.be.lt(beforeWallet); // spent something

    // TVL vs aUSDC balance in the mock: must match exactly
    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    // System balance: TotalMarketsValue + totalFreeCollateral == totalValueLocked
    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    // Solvency holds for trader and mm address (the MM contract)
    const okTrader = await fx.ledger.invariant_checkSolvencyAllMarkets(
      fx.trader.address
    );
    const okMM = await fx.ledger.invariant_checkSolvencyAllMarkets(
      await mm.getAddress()
    );
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);

    // Redeemability margin for mm should be >= 0
    const [netAlloc, redeemable, margin] =
      await fx.ledger.invariant_redeemabilityState(
        await mm.getAddress(),
        marketId
      );
    expect(margin).to.be.gte(0n);
  });

  it("buyForUSDCWithUSDC path works and preserves invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Fresh trader USDC
    await fx.usdc.mint(fx.trader.address, usdc("500")); // 500 USDC
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), usdc("500"));

    const beforeWallet = await fx.usdc.balanceOf(fx.trader.address);

    // Trader spends exactly 200 USDC from wallet and gets tokens
    await fx.ledger
      .connect(fx.trader)
      .buyForUSDCWithUSDC(
        await mm.getAddress(),
        marketId,
        positionId,
        true,              // isBack
        usdc("200"),       // usdcFromWallet
        0n,                // minTokensOut (accept any)
        0,                 // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );

    const afterWallet = await fx.usdc.balanceOf(fx.trader.address);
    expect(beforeWallet - afterWallet).to.equal(usdc("200"));

    // TVL vs aUSDC balance
    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    // System balance invariant
    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });

  it("sellExactTokensForUSDCToWallet credits wallet and keeps invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Step 1: trader deposits USDC and buys some tokens via ppUSDC path
    await fx.usdc.mint(fx.trader.address, usdc("1000"));
    await fx.usdc
      .connect(fx.trader)
      .approve(await fx.ledger.getAddress(), usdc("1000"));

    // Simple deposit -> ppUSDC / freeCollateral
    await fx.ledger
      .connect(fx.trader)
      .deposit(
        fx.trader.address,   // to
        usdc("1000"),        // amount
        0,                   // minUSDCDeposited
        0,                   // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );

    // Buy 20 tokens from mm using ppUSDC freeCollateral
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        usdc("20"),    // t
        usdc("1000")   // maxUSDCIn
      );

    // Step 2: now sell 5 tokens and withdraw USDC directly to wallet
    const beforeWallet = await fx.usdc.balanceOf(fx.trader.address);

    await fx.ledger
      .connect(fx.trader)
      .sellExactTokensForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        usdc("5"),     // t = 5 tokens
        0n,            // minUSDCOut
        fx.trader.address
      );

    const afterWallet = await fx.usdc.balanceOf(fx.trader.address);
    expect(afterWallet).to.be.gt(beforeWallet); // received some USDC proceeds

    // TVL vs aUSDC: still consistent
    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    const okTrader = await fx.ledger.invariant_checkSolvencyAllMarkets(
      fx.trader.address
    );
    const okMM = await fx.ledger.invariant_checkSolvencyAllMarkets(
      await mm.getAddress()
    );
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);
  });

  it("sellForUSDCToWallet withdraws exact USDC and keeps invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Prep: deposit and buy some tokens so trader can sell later
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

    // Buy 30 tokens with ppUSDC
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,
        usdc("30"),
        usdc("1000")
      );

    const beforeWallet = await fx.usdc.balanceOf(fx.trader.address);

    // Sell for a modest 10 USDC out to wallet (ensures delta >= usdcOut)
    const targetUSDCOut = usdc("10");

    await fx.ledger
      .connect(fx.trader)
      .sellForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,
        targetUSDCOut,   // usdcOut
        usdc("1000"),    // maxTokensIn (big cap)
        fx.trader.address
      );

    const afterWallet = await fx.usdc.balanceOf(fx.trader.address);

    // Wallet must gain exactly targetUSDCOut (contract guarantees this path)
    expect(afterWallet - beforeWallet).to.equal(targetUSDCOut);

    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });

  it("allows sell-for-USDC to wallet when DMM has backing capital and invariants remain satisfied", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // --- Setup: give DMM backing capital + trader some position tokens ---

    // Fund DMM with an extra big deposit so redeemability is very safe
    await fx.usdc.mint(fx.owner.address, usdc("1000000")); // 1m USDC
    await fx.usdc
      .connect(fx.owner)
      .approve(await fx.ledger.getAddress(), usdc("1000000"));

    await fx.ledger
      .connect(fx.owner)
      .deposit(
        await mm.getAddress(), // DMM account
        usdc("500000"),        // +500k USDC freeCollateral for DMM
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Trader: deposit + buy some tokens so they have something to sell
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

    // Buy 30 tokens with ppUSDC (similar scale to the USDC path tests)
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        usdc("30"),    // t
        usdc("1000")   // maxUSDCIn
      );

    const beforeWallet = await fx.usdc.balanceOf(fx.trader.address);

    // --- Action: sell-for-USDC directly to wallet with a *safe* usdcOut ---
    const targetUSDCOut = usdc("10"); // 10 USDC is comfortably below the delta

    await fx.ledger
      .connect(fx.trader)
      .sellForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,            // isBack
        targetUSDCOut,   // usdcOut
        usdc("1000"),    // maxTokensIn (big cap)
        fx.trader.address
      );

    const afterWallet = await fx.usdc.balanceOf(fx.trader.address);

    // Wallet must gain exactly targetUSDCOut on this path
    expect(afterWallet - beforeWallet).to.equal(targetUSDCOut);

    // Invariants still good
    const [tvl, aBal] = await fx.ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await fx.ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    const okTrader = await fx.ledger.invariant_checkSolvencyAllMarkets(
      fx.trader.address
    );
    const okMM = await fx.ledger.invariant_checkSolvencyAllMarkets(
      await mm.getAddress()
    );
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);

    const [netAlloc, redeemable, margin] =
      await fx.ledger.invariant_redeemabilityState(
        await mm.getAddress(),
        marketId
      );
    expect(margin).to.be.gte(0n);
  });
});
