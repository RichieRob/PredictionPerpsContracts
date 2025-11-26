const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – redeemability with wallet flows", function () {
  let owner, trader;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId;

  // ----------------- helpers -----------------

  async function deployCore() {
    [owner, trader] = await ethers.getSigners();

    // --- deploy tokens & mocks ---
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

    // create market with ISC line
    const ISC_LINE = ethers.parseUnits("100000", 6);
    await ledger.createMarket(
      "Redeemability Test Market",
      "REDM",
      await flatMM.getAddress(),
      ISC_LINE
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // single YES position
    const posMeta = [{ name: "YES", ticker: "YES" }];
    const tx = await ledger.createPositions(marketId, posMeta);
    await tx.wait();

    const posIds = await ledger.getMarketPositions(marketId);
    positionId = posIds[0];
  }

  function emptyPermit() {
    return {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };
  }

  async function depositForTrader(amount) {
    await usdc.mint(trader.address, amount);
    await usdc
      .connect(trader)
      .approve(await ledger.getAddress(), amount);

    await ledger.connect(trader).deposit(
      trader.address,
      amount,
      0, // minUSDCDeposited
      0, // mode = 0 (allowance)
      emptyPermit(),
      "0x"
    );
  }

  // fund the DMM with real freeCollateral (owner deposits on its behalf)
  async function depositForDMM(amount) {
    await usdc.mint(owner.address, amount);
    await usdc
      .connect(owner)
      .approve(await ledger.getAddress(), amount);

    await ledger.connect(owner).deposit(
      await flatMM.getAddress(), // ledger account that gets freeCollateral
      amount,
      0,
      0,
      emptyPermit(),
      "0x"
    );
  }

  beforeEach(async () => {
    await deployCore();
  });

  // ----------------- tests -----------------

  it("preserves solvency & redeemability when selling exact tokens to wallet", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("5000", 6);
    const BUY_TOKENS     = ethers.parseUnits("100", 6);
    const MAX_USDC_IN    = ethers.parseUnits("5000", 6);
    const SELL_TOKENS    = ethers.parseUnits("40", 6);

    await depositForTrader(TRADER_DEPOSIT);

    // build a long position
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      BUY_TOKENS,
      MAX_USDC_IN
    );

    const walletBefore = await usdc.balanceOf(trader.address);

    // sell some of that position and withdraw proceeds directly to wallet
    await ledger.connect(trader).sellExactTokensForUSDCToWallet(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      SELL_TOKENS,
      0,                // minUSDCOut = 0
      trader.address
    );

    const walletAfter = await usdc.balanceOf(trader.address);
    expect(walletAfter).to.be.gt(walletBefore);

    // --- invariants: trader side ---

    const effMin = await ledger.invariant_effectiveMin(
      trader.address,
      marketId
    );
    expect(effMin).to.be.gte(0n);

    const [netAlloc, redeemable, margin] =
      await ledger.invariant_redeemabilityState(trader.address, marketId);

    // margin = netAlloc - redeemable, must not go negative
    expect(margin).to.be.gte(0n);
    if (redeemable > 0n) {
      expect(netAlloc).to.be.gte(redeemable);
    }

    const okAll = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okAll).to.equal(true);

    // --- system level TVL vs aUSDC still consistent ---

    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
    expect(aUSDCAfter).to.equal(tvlAfter);
  });

  it("reverts when a sell-for-USDC would violate DMM redeemability (no DMM capital)", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("5000", 6);
    const BUY_TOKENS     = ethers.parseUnits("150", 6);
    const MAX_USDC_IN    = ethers.parseUnits("5000", 6);

    await depositForTrader(TRADER_DEPOSIT);

    // Trader buys to create a long position against the DMM
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      BUY_TOKENS,
      MAX_USDC_IN
    );

    // With no DMM freeCollateral, this sell-for-USDC would force the DMM into:
    //   redeemable(DMM) > netUSDCAllocation(DMM)
    // ensureSolvency(dmm) tries to allocate real capital from freeCollateral[dmm],
    // finds 0, and reverts via 3_AllocateCapitalLib with "Insufficient free collateral".
    const TARGET_USDC_OUT = ethers.parseUnits("300", 6);
    const MAX_TOKENS_IN   = ethers.parseUnits("400", 6);

    await expect(
      ledger.connect(trader).sellForUSDCToWallet(
        await flatMM.getAddress(),
        marketId,
        positionId,
        true,
        TARGET_USDC_OUT,
        MAX_TOKENS_IN,
        trader.address
      )
    ).to.be.revertedWith("Insufficient free collateral");
  });

  it("allows sell-for-USDC to wallet when DMM has backing capital and invariants remain satisfied", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("5000", 6);
    const BUY_TOKENS     = ethers.parseUnits("150", 6);
    const MAX_USDC_IN    = ethers.parseUnits("5000", 6);

    // fund trader and DMM
    await depositForTrader(TRADER_DEPOSIT);

    // give the DMM some real freeCollateral to lean on
    const DMM_FUNDING = ethers.parseUnits("10000", 6);
    await depositForDMM(DMM_FUNDING);

    // Trader buys to create a long position
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      BUY_TOKENS,
      MAX_USDC_IN
    );

    const TARGET_USDC_OUT = ethers.parseUnits("300", 6);
    const MAX_TOKENS_IN   = ethers.parseUnits("400", 6);

    const walletBefore = await usdc.balanceOf(trader.address);

    // This time, with DMM funded, ensureSolvency(dmm) can allocate from
    // freeCollateral[dmm] to keep:
    //   effMin(dmm) >= 0 and netAlloc(dmm) >= redeemable(dmm)
    await ledger.connect(trader).sellForUSDCToWallet(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      TARGET_USDC_OUT,
      MAX_TOKENS_IN,
      trader.address
    );

    const walletAfter = await usdc.balanceOf(trader.address);
    expect(walletAfter).to.be.gt(walletBefore);

    // --- invariants on trader ---

    const effMinTrader = await ledger.invariant_effectiveMin(
      trader.address,
      marketId
    );
    expect(effMinTrader).to.be.gte(0n);

    const [netAllocTrader, redeemableTrader, marginTrader] =
      await ledger.invariant_redeemabilityState(trader.address, marketId);

    expect(marginTrader).to.be.gte(0n);
    if (redeemableTrader > 0n) {
      expect(netAllocTrader).to.be.gte(redeemableTrader);
    }

    const okTrader = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okTrader).to.equal(true);

    // --- (optional) invariants on DMM as well ---

    const effMinDMM = await ledger.invariant_effectiveMin(
      await flatMM.getAddress(),
      marketId
    );
    expect(effMinDMM).to.be.gte(0n);

    const [netAllocDMM, redeemableDMM, marginDMM] =
      await ledger.invariant_redeemabilityState(
        await flatMM.getAddress(),
        marketId
      );

    expect(marginDMM).to.be.gte(0n);
    if (redeemableDMM > 0n) {
      expect(netAllocDMM).to.be.gte(redeemableDMM);
    }

    const okDMM = await ledger.invariant_checkSolvencyAllMarkets(
      await flatMM.getAddress()
    );
    expect(okDMM).to.equal(true);

    // --- system TVL vs aUSDC (mock: equality) ---

    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
    expect(aUSDCAfter).to.equal(tvlAfter);
  });
});
