const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – invariants after a trade", function () {
  let owner, trader, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId;

  beforeEach(async () => {
    [owner, trader, dmm] = await ethers.getSigners();

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

    // --- create market + one position with an ISC line ---
    const ISC_LINE = ethers.parseUnits("100000", 6);

    await ledger.createMarket(
      "Test Market",
      "TEST",
      await flatMM.getAddress(),
      ISC_LINE
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    const posMeta = [{ name: "YES", ticker: "YES" }];
    const tx = await ledger.createPositions(marketId, posMeta);
    await tx.wait();

    const posIds = await ledger.getMarketPositions(marketId);
    positionId = posIds[0];
  });

  it("keeps market accounting, system balance, TVL, ISC line and redeemability invariants after a buy", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("1000", 6);
    const TOKENS_TO_BUY  = ethers.parseUnits("10", 6);
    const MAX_USDC_IN    = ethers.parseUnits("1000", 6);

    // --- 1) fund trader + deposit ---
    await usdc.mint(trader.address, TRADER_DEPOSIT);
    await usdc
      .connect(trader)
      .approve(await ledger.getAddress(), TRADER_DEPOSIT);

    const emptyPermit = {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };

    await ledger.connect(trader).deposit(
      trader.address,
      TRADER_DEPOSIT,
      0, // minUSDCDeposited
      0, // mode = 0 (allowance)
      emptyPermit,
      "0x"
    );

    // snapshot TVL and aUSDC balance before
    const [tvlBefore, aUSDCBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCBefore);
    expect(tvlBefore).to.equal(TRADER_DEPOSIT);

    // --- 2) execute a buy ---
    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true, // isBack
      TOKENS_TO_BUY,
      MAX_USDC_IN
    );

    // --- 3) market accounting invariant ---
    const [lhsMarket, rhsMarket] = await ledger.invariant_marketAccounting(
      marketId
    );
    // marketValue == MarketUSDCSpent - Redemptions
    expect(lhsMarket).to.equal(rhsMarket);

    // --- 4) system balance sheet invariant ---
    const [lhsSys, rhsSys] = await ledger.invariant_systemBalance();
    // TotalMarketsValue + totalFreeCollateral == totalValueLocked
    expect(lhsSys).to.equal(rhsSys);

    // --- 5) TVL vs aUSDC balance (mock: no interest, so equality) ---
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();
    expect(aUSDCAfter).to.equal(tvlAfter);

    // and TVL should still be the original deposit: we only moved principal
    // between freeCollateral and marketValue.
    expect(tvlAfter).to.equal(TRADER_DEPOSIT);

    // --- 6) ISC invariant: used ISC within the line ---
    const [usedISC, iscLine] = await ledger.invariant_iscWithinLine(marketId);
    expect(iscLine).to.equal(ethers.parseUnits("100000", 6));
    expect(usedISC).to.be.gte(0n);
    expect(usedISC).to.be.lte(iscLine);

    // --- 7) DMM solvency: effective min-shares >= 0 ---
    const effMinDMM = await ledger.invariant_effectiveMin(
      await flatMM.getAddress(),
      marketId
    );
    expect(effMinDMM).to.be.gte(0n);

    // --- 8) DMM redeemability: netAlloc >= redeemable ---
    const [netAllocDMM, redeemableDMM, marginDMM] =
      await ledger.invariant_redeemabilityState(
        await flatMM.getAddress(),
        marketId
      );

    // margin = netAlloc - redeemable should never be negative
    expect(marginDMM).to.be.gte(0n);
    if (redeemableDMM > 0n) {
      expect(netAllocDMM).to.be.gte(redeemableDMM);
    }

    // --- 9) Trader redeemability: netAlloc >= redeemable ---
    const [netAllocTrader, redeemableTrader, marginTrader] =
      await ledger.invariant_redeemabilityState(
        trader.address,
        marketId
      );

    expect(marginTrader).to.be.gte(0n);
    if (redeemableTrader > 0n) {
      expect(netAllocTrader).to.be.gte(redeemableTrader);
    }
  });
});
