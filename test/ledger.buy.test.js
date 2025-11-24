const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – simple trading smoke test", function () {
  let owner, trader;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId;

  beforeEach(async () => {
    [owner, trader] = await ethers.getSigners();

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

    const MarketMakerLedger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,          // permit2 unused
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    await ppUSDC.setLedger(await ledger.getAddress());

    // 🔹 Deploy flat market maker
    const FlatMockMarketMaker = await ethers.getContractFactory("FlatMockMarketMaker");
    flatMM = await FlatMockMarketMaker.deploy();
    await flatMM.waitForDeployment();

    // 🔹 Allow it as DMM
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // 🔹 Give market an ISC line (pure synthetic)
    const iscAmount = ethers.parseUnits("100000", 6); // 100k synthetic
    await ledger.createMarket(
      "Test Market",
      "TEST",
      await flatMM.getAddress(),
      iscAmount
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // create ONE position
    const tx = await ledger.createPosition(
      marketId,
      "YES",
      "YES"
    );
    await tx.wait();

    const posIds = await ledger.getMarketPositions(marketId);
    positionId = posIds[0];
  });

  it("lets a trader deposit and try a buy", async () => {
    const TRADER_DEPOSIT = ethers.parseUnits("1000", 6); // 1,000 USDC

    // mint & approve
    await usdc.mint(trader.address, TRADER_DEPOSIT);
    await usdc.connect(trader).approve(await ledger.getAddress(), TRADER_DEPOSIT);

    // deposit with mode=0 (allowance)
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
      0,
      0,           // mode = 0 (allowance)
      emptyPermit, // unused for mode 0
      "0x"
    );

    // now try an internal ppUSDC trade:
    const TOKENS_TO_BUY = ethers.parseUnits("10", 6);   // 10 tokens
    const MAX_USDC_IN   = ethers.parseUnits("1000", 6); // up to 1000 USDC

    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),  // 👈 actual MM contract
      marketId,
      positionId,
      true,                 // isBack
      TOKENS_TO_BUY,
      MAX_USDC_IN
    );

    // sanity check: freeCollateral down
    const free = await ledger.freeCollateralOf(trader.address);
    expect(free).to.be.lt(TRADER_DEPOSIT);

    const [freeC, exposure, tilt] = await ledger.getPositionLiquidity(
      trader.address,
      marketId,
      positionId
    );
    // console.log({ freeC: freeC.toString(), exposure: exposure.toString(), tilt: tilt.toString() });
  });
});
