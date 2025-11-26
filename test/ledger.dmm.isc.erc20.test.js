const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – DMM ISC + ERC20 mirrors", function () {
  let owner, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, positionId, positionToken;

  async function deployCore() {
    [owner, dmm] = await ethers.getSigners();

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
    flatMM = await FlatMockMarketMaker.connect(dmm).deploy();
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

    // allow the DMM
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // --- market with ISC, but no trader activity ---
    const ISC_LINE = ethers.parseUnits("100000", 6);

    await ledger.createMarket(
      "DMM ISC Mirror Market",
      "DIMM",
      await flatMM.getAddress(),
      ISC_LINE,
      false,
     ethers.ZeroAddress,
      "0x"
    );

    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // Predict return values, then execute once so ERC20 is actually registered
    const [predictedPosId, predictedToken] =
      await ledger.createPosition.staticCall(marketId, "YES", "YES");

    await ledger.createPosition(marketId, "YES", "YES");

    positionId = predictedPosId;
    positionToken = predictedToken;
  }

  beforeEach(async () => {
    await deployCore();
  });

  it("gives the DMM the full ISC as created shares and matches ERC20 supply", async () => {
    const dmmAddr    = await flatMM.getAddress();
    const ledgerAddr = await ledger.getAddress();

    // TVL should be zero before any real capital goes in
    const [tvl, aUSDCBal] = await ledger.invariant_tvl();
    expect(tvl).to.equal(0n);
    expect(aUSDCBal).to.equal(0n);

    // ISC invariants: used == 0, line == configured ISC
    const [iscUsed, iscLine] = await ledger.invariant_iscWithinLine(marketId);
    expect(iscUsed).to.equal(0n);

    // ERC20 totalSupply = marketValue + ISC
    const ts = await ledger.erc20TotalSupply(positionToken);
    expect(ts).to.equal(iscLine);

    // DMM should hold the full ISC as created shares initially
    const balDMM = await ledger.erc20BalanceOf(positionToken, dmmAddr);
    expect(balDMM).to.equal(iscLine);

    // No phantom balances elsewhere
    const balOwner  = await ledger.erc20BalanceOf(positionToken, owner.address);
    const balLedger = await ledger.erc20BalanceOf(positionToken, ledgerAddr);

    expect(balOwner).to.equal(0n);
    expect(balLedger).to.equal(0n);

    // Sum of balances == totalSupply
    const sum = balDMM + balOwner + balLedger;
    expect(sum).to.equal(ts);

    // DMM is solvent and passes invariants
    const effMin = await ledger.invariant_effectiveMin(dmmAddr, marketId);
    expect(effMin).to.be.gte(0n);

    const [netAlloc, redeemable, margin] =
      await ledger.invariant_redeemabilityState(dmmAddr, marketId);
    expect(margin).to.be.gte(0n);
    if (redeemable > 0n) {
      expect(netAlloc).to.be.gte(redeemable);
    }

    const okAll = await ledger.invariant_checkSolvencyAllMarkets(dmmAddr);
    expect(okAll).to.equal(true);
  });
});
