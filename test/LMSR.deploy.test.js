const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LMSRMarketMaker – deployment & basic quotes", function () {
  let owner, trader, governor;
  let usdc;
  let ledger;
  let amm;
  let marketId;
  let posA;
  let posB;

  beforeEach(async function () {
    [owner, trader, governor] = await ethers.getSigners();

    // 1) Mock USDC (not used by AMM directly yet, but handy to have around)
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    // 2) Mock ledger (only for positionExists + seedPosition)
    const MockLedger = await ethers.getContractFactory("MockLedger");
    ledger = await MockLedger.deploy();
    await ledger.waitForDeployment(); // NEW: Deploy PositionERC20 and set it const PositionERC20 = await ethers.getContractFactory("PositionERC20"); const positionImpl = await PositionERC20.deploy(await fx.ledger.getAddress()); await positionImpl.waitForDeployment(); await fx.ledger.connect(fx.owner).setPositionERC20Implementation(await positionImpl.getAddress());

    // 3) Deploy LMSRMarketMaker(governor, ledger)
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    amm = await LMSR.deploy(
      governor.address,
      await ledger.getAddress()
    );
    await amm.waitForDeployment();

    // 4) Seed two positions in the mock ledger
    marketId = 1;
    posA = 101;
    posB = 102;

    await ledger.seedPosition(marketId, posA);
    await ledger.seedPosition(marketId, posB);

    // 5) Init market with 2 outcomes, 50/50, no reserve, not expanding
    const initialPositions = [
      { positionId: posA, r: ethers.parseEther("0.5") },
      { positionId: posB, r: ethers.parseEther("0.5") },
    ];

    // e.g. 1000 USDC maximum liability, 1e6-scaled
    const liabilityUSDC = 1_000_000n * 1000n;

    await amm
      .connect(governor)
      .initMarket(
        marketId,
        initialPositions,
        liabilityUSDC,
        0,      // reserve0
        false   // isExpanding
      );
  });

  it("returns sensible initial prices", async function () {
    const half = ethers.parseEther("0.5");

    const pA = await amm.getBackPriceWad(marketId, posA);
    const pB = await amm.getBackPriceWad(marketId, posB);

    // ~0.5 each, 1e18-scaled
    expect(pA).to.be.closeTo(half, half / 1_000_000n);
    expect(pB).to.be.closeTo(half, half / 1_000_000n);
  });

  it("quotes a buy and updates price in the right direction", async function () {
    // initial price ~ 0.5
    const pBefore = await amm.getBackPriceWad(marketId, posA);
    const half = ethers.parseEther("0.5");
    expect(pBefore).to.be.closeTo(half, half / 1_000_000n);

    const t = 1_000_000n; // 1.0 in your 1e6 token units (arbitrary)

    // big max cap so we don’t trip slippage checks
    const maxUSDCInCap = 10_000_000_000_000_000n;

    // 1) Static quote via applyBuyExactTokens.staticCall
    const usdcInQuoted = await amm
      .connect(trader)
      .applyBuyExactTokens.staticCall(
        marketId,
        posA,
        true,         // isBack
        t,
        maxUSDCInCap
      );

    expect(usdcInQuoted).to.be.gt(0n);

    // 2) Execute the trade for real
    const tx = await amm
      .connect(trader)
      .applyBuyExactTokens(
        marketId,
        posA,
        true,        // isBack
        t,
        maxUSDCInCap
      );
    await tx.wait();

    // 3) Price of posA should have gone up
    const pAfter = await amm.getBackPriceWad(marketId, posA);
    expect(pAfter).to.be.gt(pBefore);
  });
});
