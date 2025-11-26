const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – solvency & redeemability edge cases", function () {
  let owner, trader;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId;

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

    await ppUSDC.setLedger(await ledger.getAddress());

    // allow flatMM as DMM
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // create a market with an ISC line for the DMM
    const ISC_LINE = ethers.parseUnits("100000", 6);
    await ledger.createMarket(
      "Solvency Test Market",
      "SOLV",
      await flatMM.getAddress(),
      ISC_LINE,
      false,
      ethers.ZeroAddress,
      "0x"
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

  beforeEach(async () => {
    await deployCore();
  });

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
      0,          // minUSDCDeposited
      0,          // mode = 0 (allowance)
      emptyPermit(),
      "0x"
    );
  }

  it("keeps effMin >= 0 and margin >= 0 after multiple buys", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("5000", 6); // 5,000 USDC
    const TOKENS_TO_BUY = ethers.parseUnits("50", 6);    // 50 tokens per buy

    await depositForTrader(TRADER_DEPOSIT);

    // three sequential buys to crank up exposure
    for (let i = 0; i < 3; i++) {
      await ledger.connect(trader).buyExactTokens(
        await flatMM.getAddress(),
        marketId,
        positionId,
        true, // isBack
        TOKENS_TO_BUY,
        TRADER_DEPOSIT // generous maxUSDCIn
      );
    }

    // --- trader's solvency & redeemability state ---
    const effMin = await ledger.invariant_effectiveMin(
      trader.address,
      marketId
    );
    expect(effMin).to.be.gte(0n);

    const [netAlloc, redeemable, margin] =
      await ledger.invariant_redeemabilityState(trader.address, marketId);

    // margin = netAlloc - redeemable, should never be negative
    expect(margin).to.be.gte(0n);

    // sanity: if redeemable > 0, then netAlloc must be at least as large
    if (redeemable > 0n) {
      expect(netAlloc).to.be.gte(redeemable);
    }

    // cross-check the global helper
    const okAll = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okAll).to.equal(true);
  });

  it("keeps effMin >= 0 and margin >= 0 after buys + partial sells", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("5000", 6);
    const BUY_TOKENS = ethers.parseUnits("100", 6);
    const SELL_TOKENS = ethers.parseUnits("30", 6);
    const MAX_USDC = ethers.parseUnits("5000", 6);

    await depositForTrader(TRADER_DEPOSIT);

    // two buys to build a chunky long
    for (let i = 0; i < 2; i++) {
      await ledger.connect(trader).buyExactTokens(
        await flatMM.getAddress(),
        marketId,
        positionId,
        true,
        BUY_TOKENS,
        MAX_USDC
      );
    }

    // then a partial sell to flatten a bit
    await ledger.connect(trader).sellExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,
      SELL_TOKENS,
      0 // minUSDCOut = 0 for simplicity
    );

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

  it("keeps DMM solvent with ISC after trader activity", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("10000", 6);
    const TOKENS_TO_BUY = ethers.parseUnits("200", 6);
    const MAX_USDC = ethers.parseUnits("10000", 6);

    await depositForTrader(TRADER_DEPOSIT);

    // hammer the DMM a bit
    for (let i = 0; i < 3; i++) {
      await ledger.connect(trader).buyExactTokens(
        await flatMM.getAddress(),
        marketId,
        positionId,
        true,
        TOKENS_TO_BUY,
        MAX_USDC
      );
    }

    // DMM address
    const dmmAddress = await flatMM.getAddress();

    const effMinDMM = await ledger.invariant_effectiveMin(
      dmmAddress,
      marketId
    );
    // by construction, the DMM should always be solvent after ISC
    expect(effMinDMM).to.be.gte(0n);

    const [netAllocDMM, redeemableDMM, marginDMM] =
      await ledger.invariant_redeemabilityState(dmmAddress, marketId);

    // marginDMM should also not go negative
    expect(marginDMM).to.be.gte(0n);
    if (redeemableDMM > 0n) {
      expect(netAllocDMM).to.be.gte(redeemableDMM);
    }

    const okAllDMM = await ledger.invariant_checkSolvencyAllMarkets(
      dmmAddress
    );
    expect(okAllDMM).to.equal(true);
  });
});
