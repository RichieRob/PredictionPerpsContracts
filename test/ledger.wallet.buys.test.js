const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – wallet-based buys", function () {
  let owner, trader;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId;

  // ----------------- helpers -----------------

  async function deployCore() {
    [owner, trader] = await ethers.getSigners();

    // --- tokens & mocks ---
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
    aUSDC = await MockAUSDC.deploy();
    await aUSDC.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress()
    );
    await aavePool.waitForDeployment();

    const PpUSDC = await ethers.getContractFactory("PpUSDC");
    ppUSDC = await PpUSDC.deploy();
    await ppUSDC.waitForDeployment();

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    flatMM = await FlatMockMarketMaker.deploy();
    await flatMM.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory(
      "MarketMakerLedger"
    );
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress, // permit2 (unused)
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // allow DMM
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // --- market + single YES position ---
    const ISC_LINE = ethers.parseUnits("100000", 6);
    await ledger.createMarket(
      "Wallet Buy Test Market",
      "WALB",
      await flatMM.getAddress(),
      ISC_LINE
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    const metas = [{ name: "YES", ticker: "YES" }];
    await (await ledger.createPositions(marketId, metas)).wait();
    const posIds = await ledger.getMarketPositions(marketId);
    positionId = posIds[0];
  }

  function emptyEipPermit() {
    return {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };
  }

  beforeEach(async () => {
    await deployCore();
  });

  // ----------------- tests -----------------

  it("routes buyExactTokensWithUSDC via depositFromTraderUnified + maintains invariants", async () => {
    const WALLET_USDC  = ethers.parseUnits("5000", 6);
    const TOKENS_OUT   = ethers.parseUnits("100", 6);
    const MAX_USDC_IN  = ethers.parseUnits("5000", 6);

    // fund trader wallet
    await usdc.mint(trader.address, WALLET_USDC);
    await usdc
      .connect(trader)
      .approve(await ledger.getAddress(), WALLET_USDC);

    const walletBefore = await usdc.balanceOf(trader.address);
    const ppBefore     = await ppUSDC.balanceOf(trader.address);
    const freeBefore   = await ledger.freeCollateralOf(trader.address);
    const [tvlBefore, aUSDCAfterBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCAfterBefore);

    // mode = 0 (allowance)
    await ledger.connect(trader).buyExactTokensWithUSDC(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,                  // back
      TOKENS_OUT,
      MAX_USDC_IN,
      0,                     // mode: allowance
      emptyEipPermit(),
      "0x"                   // permit2 calldata
    );

    const walletAfter = await usdc.balanceOf(trader.address);
    const ppAfter     = await ppUSDC.balanceOf(trader.address);
    const freeAfter   = await ledger.freeCollateralOf(trader.address);
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();

    // wallet spent some USDC
    expect(walletAfter).to.be.lt(walletBefore);

    // trader now has some freeCollateral and ppUSDC ≥ 0
    expect(freeAfter).to.be.gte(0n);
    expect(ppAfter).to.equal(freeAfter);

    // TVL and aUSDC still in lockstep
    expect(tvlAfter).to.equal(aUSDCAfter);
    expect(tvlAfter).to.be.gt(tvlBefore); // some USDC moved into the system

    // --- invariants on trader ---

    const effMin = await ledger.invariant_effectiveMin(
      trader.address,
      marketId
    );
    expect(effMin).to.be.gte(0n);

    const [netAlloc, redeemable, margin] =
      await ledger.invariant_redeemabilityState(trader.address, marketId);
    expect(margin).to.be.gte(0n);
    if (redeemable > 0n) {
      expect(netAlloc).to.be.gte(redeemable);
    }

    const okAll = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okAll).to.equal(true);
  });

  it("routes buyForUSDCWithUSDC correctly and keeps TVL == aUSDC", async () => {
    const WALLET_USDC = ethers.parseUnits("2000", 6);
    const USDC_IN     = ethers.parseUnits("800", 6);

    await usdc.mint(trader.address, WALLET_USDC);
    await usdc
      .connect(trader)
      .approve(await ledger.getAddress(), WALLET_USDC);

    const walletBefore = await usdc.balanceOf(trader.address);
    const [tvlBefore, aUSDCAfterBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCAfterBefore);

    await ledger.connect(trader).buyForUSDCWithUSDC(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,                 // back
      USDC_IN,
      0,                    // minTokensOut
      0,                    // mode: allowance
      emptyEipPermit(),
      "0x"
    );

    const walletAfter = await usdc.balanceOf(trader.address);
    const freeAfter   = await ledger.freeCollateralOf(trader.address);
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();

    // wallet spent some USDC
    expect(walletAfter).to.be.lt(walletBefore);

    // freeCollateral is >= 0 (could be 0 if all deposit was spent)
    expect(freeAfter).to.be.gte(0n);

    // TVL vs aUSDC invariant
    expect(tvlAfter).to.equal(aUSDCAfter);
    expect(tvlAfter).to.be.gt(tvlBefore);

    const okAll = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okAll).to.equal(true);
  });
});
