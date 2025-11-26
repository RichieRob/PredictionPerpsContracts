const { expect } = require("chai");
const { ethers } = require("hardhat");

// 6-decimals helper
const usdc = (n) => {
  if (typeof n === "string") return BigInt(n) * 1_000_000n;
  return BigInt(n) * 1_000_000n;
};

const ONE = 1_000_000n; // 1 "token" in the FlatMockMarketMaker scale

// Dummy EIP-2612 struct (unused when mode = 0)
const EMPTY_PERMIT = {
  value: 0n,
  deadline: 0n,
  v: 0,
  r: "0x0000000000000000000000000000000000000000000000000000000000000000",
  s: "0x0000000000000000000000000000000000000000000000000000000000000000",
};

describe("MarketMakerLedger – USDC trade paths", function () {
  let owner, trader;
  let usdcToken, aUSDC, aavePool, ppUSDC, ledger, mm;

  beforeEach(async () => {
    [owner, trader] = await ethers.getSigners();

    // --- Deploy mocks ---
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdcToken = await MockUSDC.deploy();
    await usdcToken.waitForDeployment();

    const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
    aUSDC = await MockAUSDC.deploy();
    await aUSDC.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(
      await usdcToken.getAddress(),
      await aUSDC.getAddress()
    );
    await aavePool.waitForDeployment();

    const PpUSDC = await ethers.getContractFactory("PpUSDC");
    ppUSDC = await PpUSDC.deploy();
    await ppUSDC.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await MarketMakerLedger.deploy(
      await usdcToken.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      "0x0000000000000000000000000000000000000000", // permit2 unused in this test
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // Wire ppUSDC → ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // Flat pricing market maker contract (mm)
    const FlatMockMarketMaker = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await FlatMockMarketMaker.deploy();
    await mm.waitForDeployment();

    // Allow the mm contract as a DMM
    await ledger.allowDMM(await mm.getAddress(), true);

    // Create a simple market with this mm as DMM, no ISC
    await ledger.createMarket(
      "USDC Trade Market",
      "UTM",
      await mm.getAddress(),
      0n,
      false,
      ethers.ZeroAddress,
      "0x"
    );

    const markets = await ledger.getMarkets();
    const marketId = markets[0];

    // Two positions just to have >1 in the heap structures
    await ledger.createPosition(marketId, "Outcome A", "OA");
    await ledger.createPosition(marketId, "Outcome B", "OB");

    // --- Seed DMM free collateral so ensureSolvency can allocate() ---

    // Give owner a big USDC balance to fund the DMM
    await usdcToken.mint(owner.address, usdc(1_000_000)); // 1m USDC
    await usdcToken
      .connect(owner)
      .approve(await ledger.getAddress(), usdc(1_000_000));

    // Deposit on behalf of the DMM (mm address) so mm has freeCollateral
    await ledger
      .connect(owner)
      .deposit(
        await mm.getAddress(),   // to = DMM account
        usdc(500_000),           // 500k USDC
        0,                       // minUSDCDeposited
        0,                       // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );
  });

  async function getFirstMarketAndPositionIds() {
    const markets = await ledger.getMarkets();
    const marketId = markets[0];
    const positions = await ledger.getMarketPositions(marketId);
    const positionId = positions[0]; // Outcome A
    return { marketId, positionId };
  }

  it("buyExactTokensWithUSDC path works and preserves invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Trader gets some USDC in their wallet
    await usdcToken.mint(trader.address, usdc(1_000)); // 1000 USDC
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), usdc(1_000));

    const beforeWallet = await usdcToken.balanceOf(trader.address);

    // Trader buys 10 tokens of Outcome A with USDC directly from wallet
    await ledger
      .connect(trader)
      .buyExactTokensWithUSDC(
        await mm.getAddress(), // mm = FlatMockMarketMaker (also DMM account)
        marketId,
        positionId,
        true,                // isBack
        10n * ONE,           // t = 10 tokens
        usdc(1_000),         // maxUSDCFromWallet (more than enough)
        0,                   // mode = allowance
        EMPTY_PERMIT,
        "0x"                 // permit2Calldata
      );

    const afterWallet = await usdcToken.balanceOf(trader.address);
    expect(afterWallet).to.be.lt(beforeWallet); // spent something

    // TVL vs aUSDC balance in the mock: must match exactly
    const [tvl, aBal] = await ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    // System balance: TotalMarketsValue + totalFreeCollateral == totalValueLocked
    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    // Solvency holds for trader and mm address (the MM contract)
    const okTrader = await ledger.invariant_checkSolvencyAllMarkets(trader.address);
    const okMM = await ledger.invariant_checkSolvencyAllMarkets(await mm.getAddress());
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);

    // Redeemability margin for mm should be >= 0
    const [netAlloc, redeemable, margin] = await ledger.invariant_redeemabilityState(
      await mm.getAddress(),
      marketId
    );
    // margin should not be negative
    expect(margin).to.be.gte(0n);
  });

  it("buyForUSDCWithUSDC path works and preserves invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Fresh trader USDC
    await usdcToken.mint(trader.address, usdc(500)); // 500 USDC
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), usdc(500));

    const beforeWallet = await usdcToken.balanceOf(trader.address);

    // Trader spends exactly 200 USDC from wallet and gets tokens
    await ledger
      .connect(trader)
      .buyForUSDCWithUSDC(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        usdc(200),     // usdcFromWallet
        0n,            // minTokensOut (accept any)
        0,             // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );

    const afterWallet = await usdcToken.balanceOf(trader.address);
    expect(beforeWallet - afterWallet).to.equal(usdc(200));

    // TVL vs aUSDC balance
    const [tvl, aBal] = await ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    // System balance invariant
    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });

  it("sellExactTokensForUSDCToWallet credits wallet and keeps invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Step 1: trader deposits USDC and buys some tokens via ppUSDC path
    await usdcToken.mint(trader.address, usdc(1_000));
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), usdc(1_000));

    // Simple deposit -> ppUSDC / freeCollateral
    await ledger
      .connect(trader)
      .deposit(
        trader.address,       // to
        usdc(1_000),          // amount
        0,                    // minUSDCDeposited
        0,                    // mode = allowance
        EMPTY_PERMIT,
        "0x"
      );

    // Buy 20 tokens from mm using ppUSDC freeCollateral
    await ledger
      .connect(trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        20n * ONE,     // t
        usdc(1_000)    // maxUSDCIn
      );

    // Step 2: now sell 5 tokens and withdraw USDC directly to wallet
    const beforeWallet = await usdcToken.balanceOf(trader.address);

    await ledger
      .connect(trader)
      .sellExactTokensForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        5n * ONE,      // t = 5 tokens
        0n,            // minUSDCOut
        trader.address // to
      );

    const afterWallet = await usdcToken.balanceOf(trader.address);
    expect(afterWallet).to.be.gt(beforeWallet); // received some USDC proceeds

    // TVL vs aUSDC: still consistent
    const [tvl, aBal] = await ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    const okTrader = await ledger.invariant_checkSolvencyAllMarkets(trader.address);
    const okMM = await ledger.invariant_checkSolvencyAllMarkets(await mm.getAddress());
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);
  });

  it("sellForUSDCToWallet withdraws exact USDC and keeps invariants", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // Prep: deposit and buy some tokens so trader can sell later
    await usdcToken.mint(trader.address, usdc(1_000));
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), usdc(1_000));

    await ledger
      .connect(trader)
      .deposit(
        trader.address,
        usdc(1_000),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Buy 30 tokens with ppUSDC
    await ledger
      .connect(trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,
        30n * ONE,
        usdc(1_000)
      );

    const beforeWallet = await usdcToken.balanceOf(trader.address);

    // Sell for a modest 10 USDC out to wallet (ensures delta >= usdcOut)
    const targetUSDCOut = usdc(10);

    await ledger
      .connect(trader)
      .sellForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,
        targetUSDCOut, // usdcOut
        1_000n * ONE,  // maxTokensIn, big cap
        trader.address
      );

    const afterWallet = await usdcToken.balanceOf(trader.address);

    // Wallet must gain exactly targetUSDCOut (contract guarantees this path)
    expect(afterWallet - beforeWallet).to.equal(targetUSDCOut);

    const [tvl, aBal] = await ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });

  it("allows sell-for-USDC to wallet when DMM has backing capital and invariants remain satisfied", async function () {
    const { marketId, positionId } = await getFirstMarketAndPositionIds();

    // --- Setup: give DMM backing capital + trader some position tokens ---

    // Fund DMM with a big deposit so redeemability is very safe
    await usdcToken.mint(owner.address, usdc(1_000_000)); // 1m USDC
    await usdcToken
      .connect(owner)
      .approve(await ledger.getAddress(), usdc(1_000_000));

    await ledger
      .connect(owner)
      .deposit(
        await mm.getAddress(), // DMM account
        usdc(500_000),         // 500k USDC freeCollateral for DMM
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Trader: deposit + buy some tokens so they have something to sell
    await usdcToken.mint(trader.address, usdc(1_000));
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), usdc(1_000));

    await ledger
      .connect(trader)
      .deposit(
        trader.address,
        usdc(1_000),
        0,
        0,
        EMPTY_PERMIT,
        "0x"
      );

    // Buy 30 tokens with ppUSDC (similar scale to the USDC path tests)
    await ledger
      .connect(trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        positionId,
        true,          // isBack
        30n * ONE,     // t
        usdc(1_000)    // maxUSDCIn
      );

    const beforeWallet = await usdcToken.balanceOf(trader.address);

    // --- Action: sell-for-USDC directly to wallet with a *safe* usdcOut ---

    // We purposely choose a modest usdcOut so that:
    //   netFreeDelta >= usdcOut
    // and the new guard does NOT revert.
    const targetUSDCOut = usdc(10); // 10 USDC is comfortably below the delta

    await ledger
      .connect(trader)
      .sellForUSDCToWallet(
        await mm.getAddress(),
        marketId,
        positionId,
        true,            // isBack
        targetUSDCOut,   // usdcOut
        1_000n * ONE,    // maxTokensIn (big cap)
        trader.address
      );

    const afterWallet = await usdcToken.balanceOf(trader.address);

    // Wallet must gain exactly targetUSDCOut on this path
    expect(afterWallet - beforeWallet).to.equal(targetUSDCOut);

    // Invariants still good
    const [tvl, aBal] = await ledger.invariant_tvl();
    expect(aBal).to.equal(tvl);

    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);

    const okTrader = await ledger.invariant_checkSolvencyAllMarkets(trader.address);
    const okMM = await ledger.invariant_checkSolvencyAllMarkets(await mm.getAddress());
    expect(okTrader).to.equal(true);
    expect(okMM).to.equal(true);

    const [netAlloc, redeemable, margin] = await ledger.invariant_redeemabilityState(
      await mm.getAddress(),
      marketId
    );
    expect(margin).to.be.gte(0n);
  });

});
