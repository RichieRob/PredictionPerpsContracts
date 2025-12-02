// test/resolution.freeze.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, EMPTY_PERMIT, mintAndDeposit } = require("./helpers/core");
const { expectCoreSystemInvariants } = require("./helpers/markets");
const {
  resolveViaMockOracle,
  assertWinnerPayout,
  assertMarketFrozenFor,
} = require("./helpers/resolution");

describe("MarketMakerLedger – resolution freezes trading & ERC20 views", () => {
  let fx;
  let mm;
  let oracle;
  let marketId;
  let posA;
  let posAToken;

  // ----------------- shared setup -----------------

  beforeEach(async () => {
    fx = await deployCore();

    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    mm = await Flat.deploy();
    await mm.waitForDeployment();

    const MockOracle = await ethers.getContractFactory("MockOracle");
    oracle = await MockOracle.deploy();
    await oracle.waitForDeployment();

    await fx.ledger.createMarket(
      "Election 2028",
      "EL",
      ethers.ZeroAddress,            // no DMM for resolving markets
      0,                             // no ISC
      true,                          // doesResolve = true
      await oracle.getAddress(),     // oracle
      "0x");

    marketId = (await fx.ledger.getMarkets())[0];

    await fx.ledger.createPosition(marketId, "Alice", "A");
    await fx.ledger.createPosition(marketId, "Bob",   "B");

    const positions = await fx.ledger.getMarketPositions(marketId);
    posA = positions[0];

    const posATokenAddr = await fx.ledger.getPositionERC20(marketId, posA);
    const PositionERC20 = await ethers.getContractFactory("PositionERC20");
    posAToken = PositionERC20.attach(posATokenAddr);

    // --- Fund trader & MM using helpers ---

    // Trader: 1000 USDC → ledger
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: usdc("1000"),
    });

    // MM: 1500 USDC → ledger, credited to mm address
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.owner,
      to: await mm.getAddress(),
      amount: usdc("1500"),
    });

    // Trader buys 200 A from MM
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokens(
        await mm.getAddress(),
        marketId,
        posA,
        true,
        usdc("200"),
        usdc("1000")
      );
  });

  // ----------------- tests -----------------

  it("freezes trading, zeroes ERC20 views and credits ppUSDC by the winning token count", async () => {
    const preTokenBal = await posAToken.balanceOf(fx.trader.address);
    expect(preTokenBal).to.be.gt(0n);

    const prePpBal = await fx.ppUSDC.balanceOf(fx.trader.address);

    // 1) resolve (A wins) via shared helper
    await resolveViaMockOracle({
      oracle,
      ledger: fx.ledger,
      marketId,
      winningPositionId: posA,
    });

    // 2) ppUSDC bump = holdings of winning BACK tokens
    const ppAfterResolve = await assertWinnerPayout({
      ppUSDC: fx.ppUSDC,
      account: fx.trader.address,
      prePp: prePpBal,
      preTokenBal,
    });

    // 3) ERC20 views + trading frozen
    await assertMarketFrozenFor({
      ledger: fx.ledger,
      posToken: posAToken,
      account: fx.trader.address,
      mmAddr: await mm.getAddress(),
      marketId,
      positionId: posA,
      preTokenBalForTransferCheck: preTokenBal,
    });

    // 4) claim is a no-op on visible ppUSDC (lazy bookkeeping only)
    const preClaimPp = ppAfterResolve;
    await fx.ledger.connect(fx.trader).claimAllPendingWinnings();
    const postClaimPp = await fx.ppUSDC.balanceOf(fx.trader.address);
    expect(postClaimPp).to.equal(preClaimPp);

    // 5) invariants via shared helper
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, await mm.getAddress()],
      marketId,
      checkRedeemabilityFor: [fx.trader.address, await mm.getAddress()],
    });
  });

  it("next-multi-wallet-resolution: multiple traders, split winners and losers (system-funded payout)", async () => {
    const mmAddr = await mm.getAddress();
    const [, , trader2Signer] = await ethers.getSigners();
    const trader2 = trader2Signer.address;

    // Trader 2 deposits 1000 via helper
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: trader2Signer,
      amount: usdc("1000"),
    });

    // Both traders buy A
    await fx.ledger
      .connect(fx.trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posA,
        true,
        usdc("100"),
        usdc("1000")
      );

    await fx.ledger
      .connect(trader2Signer)
      .buyExactTokens(
        mmAddr,
        marketId,
        posA,
        true,
        usdc("300"),
        usdc("2000")
      );

    // Snapshot before resolution
    const preToken1 = await posAToken.balanceOf(fx.trader.address);
    const preToken2 = await posAToken.balanceOf(trader2);
    expect(preToken1).to.be.gt(0n);
    expect(preToken2).to.be.gt(0n);

    const prePp1 = await fx.ppUSDC.balanceOf(fx.trader.address);
    const prePp2 = await fx.ppUSDC.balanceOf(trader2);
    const prePpMM = await fx.ppUSDC.balanceOf(mmAddr);

    const mmTok = await posAToken.balanceOf(mmAddr);
    expect(mmTok).to.equal(0n); // flat A

    // Resolve A via shared helper
    await resolveViaMockOracle({
      oracle,
      ledger: fx.ledger,
      marketId,
      winningPositionId: posA,
    });

    // Winner payouts
    const postPp1 = await assertWinnerPayout({
      ppUSDC: fx.ppUSDC,
      account: fx.trader.address,
      prePp: prePp1,
      preTokenBal: preToken1,
    });
    const postPp2 = await assertWinnerPayout({
      ppUSDC: fx.ppUSDC,
      account: trader2,
      prePp: prePp2,
      preTokenBal: preToken2,
    });

    // MM ppUSDC unchanged in this symmetric, flat-A scenario
    const postPpMM = await fx.ppUSDC.balanceOf(mmAddr);
    expect(postPpMM).to.equal(prePpMM);

    // ERC20 views frozen for all three accounts
    await assertMarketFrozenFor({
        ledger: fx.ledger,
        posToken: posAToken,
        account: fx.trader.address,
        mmAddr,
        marketId,
        positionId: posA,
        preTokenBalForTransferCheck: preToken1,
        checkTrading: true,   // explicit, but default anyway
      });
  
      await assertMarketFrozenFor({
        ledger: fx.ledger,
        posToken: posAToken,
        account: trader2,
        mmAddr,
        marketId,
        positionId: posA,
        preTokenBalForTransferCheck: preToken2,
        checkTrading: true,
      });
  
      // MM is a contract, *not* a signer → only check balances/views, skip trading
      await assertMarketFrozenFor({
        ledger: fx.ledger,
        posToken: posAToken,
        account: mmAddr,
        mmAddr,
        marketId,
        positionId: posA,
        preTokenBalForTransferCheck: 0n,
        checkTrading: false,  // 👈 important
      });

    // sanity: traders definitely up by token count
    expect(postPp1 - prePp1).to.equal(preToken1);
    expect(postPp2 - prePp2).to.equal(preToken2);

    // system invariants across multiple traders (shared helper)
    await expectCoreSystemInvariants(fx, {
      accounts: [fx.trader.address, trader2, mmAddr],
      marketId,
      checkRedeemabilityFor: [fx.trader.address, trader2, mmAddr],
    });
  });
});
