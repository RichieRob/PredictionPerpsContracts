const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – multi-market invariants", function () {
  let owner, trader;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId1, marketId2;
  let positionId1, positionId2;

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
      ethers.ZeroAddress, // permit2 unused
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // allow DMM globally
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // --- create two markets ---

    const ISC_LINE_1 = ethers.parseUnits("100000", 6);
    const ISC_LINE_2 = ethers.parseUnits("50000", 6);

    // Market 1
    await ledger.createMarket(
      "MultiMarket One",
      "MM1",
      await flatMM.getAddress(),
      ISC_LINE_1,
      false,
      ethers.ZeroAddress,
      "0x",
    );

    // Market 2
    await ledger.createMarket(
      "MultiMarket Two",
      "MM2",
      await flatMM.getAddress(),
      ISC_LINE_2,
      false,
      ethers.ZeroAddress,
      "0x"
    );

    const markets = await ledger.getMarkets();
    expect(markets.length).to.equal(2);

    marketId1 = markets[0];
    marketId2 = markets[1];

    // single YES in each market
    const posMeta1 = [{ name: "YES-1", ticker: "Y1" }];
    const tx1 = await ledger.createPositions(marketId1, posMeta1);
    await tx1.wait();

    const posIds1 = await ledger.getMarketPositions(marketId1);
    positionId1 = posIds1[0];

    const posMeta2 = [{ name: "YES-2", ticker: "Y2" }];
    const tx2 = await ledger.createPositions(marketId2, posMeta2);
    await tx2.wait();

    const posIds2 = await ledger.getMarketPositions(marketId2);
    positionId2 = posIds2[0];
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

  beforeEach(async () => {
    await deployCore();
  });

  // ----------------- tests -----------------

  it("maintains per-market + system invariants after trading in two markets", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("10000", 6);
    await depositForTrader(TRADER_DEPOSIT);

    // --- 1) snapshot TVL vs aUSDC before trades ---
    const [tvlBefore, aUSDCBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCBefore);
    expect(tvlBefore).to.equal(TRADER_DEPOSIT);

    // --- 2) trader buys in market 1 and market 2 ---

    const BUY_M1_TOKENS  = ethers.parseUnits("100", 6);
    const BUY_M2_TOKENS  = ethers.parseUnits("60", 6);
    const MAX_USDC_IN    = ethers.parseUnits("10000", 6);

    // market 1
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId1,
      positionId1,
      true,
      BUY_M1_TOKENS,
      MAX_USDC_IN
    );

    // market 2
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId2,
      positionId2,
      true,
      BUY_M2_TOKENS,
      MAX_USDC_IN
    );

    // --- 3) per-market accounting invariants ---

    const [lhsM1, rhsM1] = await ledger.invariant_marketAccounting(marketId1);
    const [lhsM2, rhsM2] = await ledger.invariant_marketAccounting(marketId2);

    // marketValue == MarketUSDCSpent - Redemptions (for each market)
    expect(lhsM1).to.equal(rhsM1);
    expect(lhsM2).to.equal(rhsM2);

    // --- 4) system balance sheet invariant ---

    const [lhsSys, rhsSys] = await ledger.invariant_systemBalance();
    // TotalMarketsValue + totalFreeCollateral == totalValueLocked
    expect(lhsSys).to.equal(rhsSys);

    // --- 5) TVL vs aUSDC (mock: equality) ---

    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
    expect(aUSDCAfter).to.equal(tvlAfter);

    // all principal still in the system, just reshuffled
    expect(tvlAfter).to.equal(TRADER_DEPOSIT);

    // --- 6) check solvency across *all* markets for trader & DMM ---

    const okTrader = await ledger.invariant_checkSolvencyAllMarkets(
      trader.address
    );
    expect(okTrader).to.equal(true);

    const okDMM = await ledger.invariant_checkSolvencyAllMarkets(
      await flatMM.getAddress()
    );
    expect(okDMM).to.equal(true);
  });

  it("keeps TotalMarketsValue equal to the sum of per-market marketValue", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("8000", 6);
    await depositForTrader(TRADER_DEPOSIT);

    const BUY_M1_TOKENS  = ethers.parseUnits("50", 6);
    const BUY_M2_TOKENS  = ethers.parseUnits("80", 6);
    const MAX_USDC_IN    = ethers.parseUnits("8000", 6);

    // trade in both markets
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId1,
      positionId1,
      true,
      BUY_M1_TOKENS,
      MAX_USDC_IN
    );

    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId2,
      positionId2,
      true,
      BUY_M2_TOKENS,
      MAX_USDC_IN
    );

    // sum marketValue across all markets
    const markets = await ledger.getMarkets();
    let sumMarketValues = 0n;

    for (const mid of markets) {
      const mv = await ledger.getMarketValue(mid);
      sumMarketValues += mv;
    }

    const totalMarketsValue = await ledger.getTotalMarketsValue();

    expect(totalMarketsValue).to.equal(sumMarketValues);
  });
});
